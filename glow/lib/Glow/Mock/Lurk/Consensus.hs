
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuasiQuotes, OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -Wall #-}

module Glow.Mock.Lurk.Consensus where

import Control.Monad.RWS
import System.IO

import Control.Lens (makeLenses,to,(^.),(%=),use,(.~),(%~))
import Data.Function


import Prelude

import Data.List as L

import qualified Data.Map as M

import Data.Maybe (fromMaybe)


import qualified Data.Text.Lazy as T
import qualified Data.Text as TT

import qualified Data.Text.Lazy.IO as TIO

import Glow.Ast.Atoms
import Glow.Consensus.Lurk
import Glow.Translate.LurkToSExpr

import qualified Data.SCargot as C
import qualified Data.SCargot.Repr as R
import qualified Data.SCargot.Repr.Basic as B

import qualified GHC.Generics as G
import Data.Aeson (ToJSON,FromJSON)
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson as A
import qualified System.Process as P
import Text.RawString.QQ
import Data.UUID
import Data.UUID.V4


import Glow.Gerbil.Types (LedgerPubKey(LedgerPubKey))

import qualified Data.ByteString.Char8 as BS



data AccountState = AccountState
  { _balance :: Int
  }
 deriving (Show, G.Generic)
makeLenses ''AccountState

instance ToJSON AccountState where
instance FromJSON AccountState where


  
data ConsensusState = ConsensusState
  { _accounts :: M.Map LedgerPubKey AccountState
  , _contracts :: M.Map UUID DeployedContract
  }
 deriving (Show, G.Generic)
makeLenses ''ConsensusState

instance ToJSON ConsensusState where
instance FromJSON ConsensusState where

  

initialConsensusState :: ConsensusState
initialConsensusState = ConsensusState M.empty M.empty

renderCall :: LMEnv -> Call -> R.SExpr Atom
renderCall e c =
  let cId = fromMaybe 0 $ L.elemIndex (c ^. caller) (e ^. identities)
  in case c ^. action of
        Publish _ ->
          B.L [ B.A (Act PUBLISH)
              , B.A (Num ( c ^. desiredStateId))
              , B.A (Num  cId) ]
        _ -> let a = case c ^. action of
                         Withdraw x -> B.L [B.A (Act WITHDRAW), renderGLValueCall $ GLNat x]
                         Deposit x -> B.L [B.A (Act DEPOSIT) , renderGLValueCall $ GLNat x]
                         _ -> B.L [] --imposible case
             in B.L
                 [ B.A (Act ACTION)
                 , B.A (Num (c ^. desiredStateId))
                 , B.A (Num (cId))
                 , a  ]




mkLurkInput :: LMEnv -> LMState -> Call -> R.SExpr Atom
mkLurkInput e s c = 
  let p :: R.SExpr Atom
      p = B.L $ (fmap renderGLValueCall (s ^. publicValues))

      a :: [R.SExpr Atom]
      a = [renderCall e c]
      pubValues :: [R.SExpr Atom]
      pubValues =  (B.A $ LK Quote ) :[(B.A $ Str (T.unpack $ T.fromStrict $ (C.encodeOne sExpPrinterA p)))]
      gk :: R.SExpr Atom
      gk =  B.L $ (B.A $ LK GlowCode) : [(B.A $ Str (T.unpack $ T.fromStrict $ TT.unlines $ (fmap (C.encodeOne sExpPrinterA . renderGLValue) (e ^. interactionParameters)) )) ]
      ac :: R.SExpr Atom
      ac = (B.A $ Str (T.unpack $ T.fromStrict $ C.encode sExpPrinterA a))
      
  in B.L [
         (B.A $ LK RunGlow),
         B.L $ pubValues,
         gk,
         if (s ^. stateId == 0) then B.L [] else B.A $ Str $  (show $ s^. stateId),
         B.L $ ([B.A $ LK Quote, ac])
         ]

     
     
verifyCall :: (MonadIO m , MonadState ConsensusState m , MonadReader UUID m) => Call -> m Bool 
verifyCall c = 
  do cUuid <- ask 
     e <- gets ((^. initializationData) . ( M.! cUuid) . (^. contracts))
     s <- gets ((^. currentState) . (M.! cUuid  ) . (^. contracts))     
     x <- liftIO $ callLurk (e ^. stateTransitionVerifierSrc) $ mkLurkInput e s c
     case x of
       "T" -> do
                 liftIO $ putStrLn $ "\nConfirmed validity of call, will execute state change."
                 return True
       lurkOutput -> do
                 -- liftIO $ putStrLn $ lurkOutput
                 liftIO $ putStrLn $ "\nUnable to confirm validity of call, won't execute state change."
                 return False
    
executeCall :: (MonadIO m , MonadState ConsensusState m , MonadReader UUID m) =>  Call -> m () 
executeCall c = do
  cUuid <- ask 
  s <- gets ((^. currentState) . (M.! cUuid  ) . (^. contracts))
  let s' = (stateId .~ c ^. desiredStateId) s
  s'' <- case c ^. action of
       Withdraw a -> modify (accounts %~ (M.adjust (balance %~ (\b -> b + a))  (c ^. caller))) >> return s' 
       Deposit a -> modify (accounts %~ (M.adjust (balance %~ (\b -> b - a))  (c ^. caller))) >> return s'
       Publish v -> return $ (publicValues %~ (++[v])) s' 
  modify (contracts %~ (M.adjust (currentState .~ s'')  cUuid))
  return ()
-- type LMS = RWST LMEnv () LMState (IO)

type CMS = RWST () () ConsensusState (IO)

type LMS = RWST UUID () ConsensusState (IO)

runAtContract :: UUID -> LMS a -> CMS (Maybe a)
runAtContract x f = do
  mbC <- M.lookup x <$> use contracts 
  case mbC of
    Nothing -> return Nothing
    Just _ -> do
      st <- get
      (a , st' , _) <- liftIO $ runRWST f x st
      put st'
      -- contracts %= M.insert x (currentState .~ s $ c) 
      return (Just a)

deployContract :: LMEnv -> CMS (Either String UUID)
deployContract x = do
  ids <- M.keys <$> use accounts
  let validIds = L.all (\i -> L.elem i ids) (x ^. identities)
  if validIds then
      do newUUID <- liftIO nextRandom
         contracts %= M.insert newUUID (DeployedContract x initialLMState) 
         return $ Right newUUID
  else return (Left "identity does not exist")

getContractState :: UUID -> CMS (Maybe LMState)
getContractState x =
  fmap (^. currentState) <$> (M.lookup x <$> use contracts)


interactWithContract :: UUID -> Call -> CMS ()
interactWithContract u x = void $ runAtContract u $ do  
  isVerified <- verifyCall x
  if isVerified
  then liftIO $ putStrLn "verified!"
  else liftIO $ putStrLn $ "not-verified!" ++ show x
  when isVerified $ executeCall x


overrideConsensusState :: ConsensusState -> CMS ()
overrideConsensusState x = put x

lurkExecutable :: FilePath
lurkExecutable = "/home/pawel/Desktop/lurk-rs/target/release/fcomm"

tempLurkSourceFile :: FilePath
tempLurkSourceFile = "/tmp/tempLurkSourceFile.json"

tempClaimFile :: FilePath
tempClaimFile = "/tmp/state-claim.json"

tempEvalFile :: FilePath
tempEvalFile = "/tmp/state-eval.txt"

emitsFile :: FilePath
emitsFile = "/tmp/emits.txt"

replExecutable :: FilePath
replExecutable = "/home/pawel/Desktop/lurk-rs/target/release/lurkrs"

callLurkDeb :: IO String
callLurkDeb = do
  emits <- readFile' tempLurkSourceFile
  putStrLn $ show emits
  let source = A.eitherDecode (BS.fromStrict $ BS.pack emits)
          >>= parseEither (\obj -> do
                             s <- obj A..: "expr"
                             s' <- s A..: "Source"
                             return (s' :: String))
  do putStrLn $ show source
  case source of 
      Left err -> putStrLn (show source) >> putStrLn err >> error "error while decoding Json"
      Right (source') -> return (source' :: String)


createEvalFile :: IO [String]
createEvalFile = do
    input <- callLurkDeb
    writeFile tempEvalFile input
    -- putStrLn $ show input
    gen <- P.readProcess replExecutable [tempEvalFile] ""
    writeFile emitsFile gen
    putStrLn $ gen
    let emits = lines $ T.unpack $ T.unlines $ removeCode $ filterEmits gen
    return (emits :: [String] )


filterEmits :: String -> [T.Text]
filterEmits x = T.splitOn (T.pack "\n") (T.pack x)

removeCode :: [T.Text] -> [T.Text]
removeCode (_:_:xs) = xs
removeCode xs = xs


clearCall :: String  -> String
clearCall x = last $ lines x

callLurk :: LurkSource -> R.SExpr Atom -> IO String
callLurk code call = do
  TIO.writeFile tempLurkSourceFile $ wrapIntoJson $ glowLurkWrapper code call 
  r' <- P.readProcess lurkExecutable ["eval","--expression",tempLurkSourceFile] ""
  let clear = clearCall r'
  let y = A.eitherDecode (BS.fromStrict $ BS.pack clear)
          >>= parseEither (\obj -> do                             
                             eout <- obj A..: "expr_out"
                             return (eout :: String))

  let stateCode = A.eitherDecode (BS.fromStrict $ BS.pack clear)
           >>= parseEither (\obj -> do
                             envOut <- obj A..: "expr"
                             return (envOut :: String))
  -- putStrLn $ "Env Out " ++ show env 
  putStrLn $ "\nLurk code:\n  " ++ show stateCode
  putStrLn $ "\nCall code:\n " ++ show call
  
  do putStrLn $ "\nLurk evaluation:\n " ++ show y
  case y of
     Left err -> putStrLn (show r') >> putStrLn err >> error "fatal error while calling lurk"
     Right (r'') -> return r''

makeVerifier :: IO()
makeVerifier = do
  verifier <- P.readProcess lurkExecutable ["eval","--expression", tempLurkSourceFile ,"--claim", "/tmp/state-claim.json" ] ""
  putStrLn $ show verifier 
  proof <- P.readProcess lurkExecutable [ "prove", "--claim", tempClaimFile, "--proof", "/tmp/state-proof.json"] ""
  putStrLn $ show proof

wrapIntoJson :: LurkSource -> T.Text
wrapIntoJson x = T.replace "<SRC>" (T.filter (\x' -> not $ L.elem x' ("\n\t" :: String))  x)
    [r|{"expr":{"Source":"<SRC>"}}|]

glowLurkWrapper :: LurkSource -> R.SExpr Atom -> T.Text
glowLurkWrapper x y = T.replace "<CALL>" (T.fromStrict $ C.encode sExpPrinterA [y] ) $ T.replace "<GLOW>" x glowOnLurkLib 

glowOnLurkLib :: LurkSource
glowOnLurkLib = [r|(letrec
    ((action (lambda (i pid a) (cons 'action (cons i (cons pid (cons a ()))))))

     (withdraw (lambda (n) (begin (emit n) (cons 'withdraw (cons n ())))))
     (deposit (lambda (n) (begin (emit n) (cons 'deposit (cons n ())))))
     (publish (lambda (i pid) (cons 'publish (cons i (cons pid ())))))
     (require (lambda (v) (cons 'require (cons v ()))))

     (mk-pure (lambda (a) (cons 'pure (cons a ()))))
     (mk-bind (lambda (a b) (cons 'bind (cons a (cons b ())))))
     (mk-next (lambda (a b) (cons 'next (cons a (cons b ())))))


     (pure mk-pure)
     (bind mk-bind)
     (next mk-next)

     
     (digestPrim (lambda (a) (cons 'digest (cons a ()) )))

     (eqPrim (lambda (a b) (eq a b)))

     
     (DIGESTNAT digestPrim)
     (==Digest eqPrim)
     (==Nat eqPrim)
     
      
     (sucNat (lambda (x) ( if (eq x ())
 			      '(t)
			      (if (car x) (cons nil (sucNat (cdr x))) (cons t (cdr x)))
			       )))
     
     (+NNATh (lambda (a b carry)
            (if (eq a ()) (if carry (sucNat b) b)
		(if (eq b ()) (if carry (sucNat a) a)
		    (if (car a)
			(if (car b) (cons carry (+NNATh (cdr a) (cdr b) t)) (cons (if carry () t) (+NNATh (cdr a) (cdr b) carry)))
			(if (car b) (cons (if carry () t) (+NNATh (cdr a) (cdr b) carry)) (cons carry (+NNATh (cdr a) (cdr b) ())))
		     )))
     	    ))
     (+NAT (lambda (a b) (+NNATh a b ())))
 

     (*NAT (lambda (a b) (if a (+NAT (if (car a) b ()) (cons () (*NAT (cdr a) b))) () ) ))

     (-NAT (lambda (a b)  (+NNATh a b (if (eq b ()) t ()))))

     (PFARROWNat (lambda (a) (if (eq 0 a) () (sucNat (PFARROWNat (- a 1))))))
     
     (NatARROWPF (lambda (a) (if a (+ (if (car a) 1 0) (* 2 (NatARROWPF (cdr a)))) 0)))

     
     (bitwise-xor (lambda (a b) 
		    (if (eq a ()) b
			(if (eq b ()) a
			    (let ((hd ( if (car a) (if (car b) NIL t ) b )) 
				  (tail (bitwise-xor (cdr a) (cdr b) )))
			      (if tail (cons hd tail) hd)
			      )))))

     (bitwise-and (lambda (a b) 
		    (if (eq a ()) ()
			(if (eq b ()) ()
			    ( let ((hd ( if (car a) (car b) NIL ) )
				   (tail (bitwise-and (cdr a) (cdr b) )))
			       (if tail (cons hd tail) hd)
			      )
			    ))))

     (atomic-action-rec (lambda (code case-bind case-next case-pure case-require case-atom)
			  (if (eq (car code) 'bind)
			     (begin (emit code)(case-bind (car (cdr code)) (car (cdr (cdr code)))))
			      (if (eq (car code) 'next) (case-next (car (cdr code)) (car (cdr (cdr code))))
			      (if (eq (car code) 'pure) (case-pure (car (cdr code)))
				  (if (eq (car code) 'require) (case-require (car (cdr code)))
				      (case-atom code (car (cdr code)) (car code)))))




			   )))
     (glow-code <GLOW>)
     (run-glow (lambda (pubs code start target)
		 (atomic-action-rec code
				    (lambda (code-a fun-b)
				      (let ((result-a (run-glow pubs code-a start target)))
					   
					(if (atom result-a) result-a
					    (let ((pubs2 (car (car result-a)))
						  (code2 (fun-b (car (cdr result-a))))
						  (start2 (car (cdr (car result-a)))))
					           (run-glow pubs2 code2 start2 target)
						   ))))
				    (lambda (code-a code-b)
				      (let ((result-a (run-glow pubs code-a start target)))
					   
					(if (atom result-a) result-a
					    (let ((pubs2 (car (car result-a)))
						  (start2 (car (cdr (car result-a)))))
					           (run-glow pubs2 code-b start2 target)
						   ))))

				    (lambda (x) (cons (cons pubs (cons start ())) (cons x ())))

				    (lambda (x) (if x (cons (cons pubs (cons start ())) (cons x ())) 'require-fail))
				    (lambda (a id h)
				                  ( if start
                                                          (let ((new-start (if (eq start id) NIL start ))
								(new-pubs (if (eq h 'publish) (cdr pubs) pubs))
								(result (if (eq h 'publish) (car pubs) 'glow-unit-lit)))
							       (cons (cons new-pubs (cons new-start ())) (cons result ())))
						             
							  (eq a target)))))))
  <CALL>
  
  )|]

coinFlip0 :: LurkSource
coinFlip0 = [r|(lambda (wagerAmount escrowAmount) (bind (publish 1 0) (lambda (commitment) (next (action 2 0 (deposit (+NNAT wagerAmount escrowAmount))) (bind (publish 3 1) (lambda (randB) (next (action 4 1 (deposit wagerAmount)) (bind (publish 5 0) (lambda (randA) (bind (pure (digestNat randA)) (lambda (mbCommitment) (next (require (==Digest commitment mbCommitment)) (bind (pure (POW3 randA randB)) (lambda (n0) (bind (pure (UMPER3 n0 (cons t nil))) (lambda (n1) (next (next (if (==Nat n1 nil) (bind (pure (*NNAT (cons nil (cons t nil)) wagerAmount)) (lambda (w1) (bind (pure (+NNAT w1 escrowAmount)) (lambda (w2) (next (action 6 0 (withdraw w2)) (pure (quote glow-unit-lit))))))) (bind (pure (*NNAT (cons nil (cons t nil)) wagerAmount)) (lambda (w1) (next (action 7 1 (withdraw w1)) (next (action 8 0 (withdraw escrowAmount)) (pure (quote glow-unit-lit))))))) (pure (quote glow-unit-lit))) (pure (quote glow-unit-lit)))))))))))))))))))|]


coinFlip :: LurkSource
coinFlip = [r|(lambda (wagerAmount escrowAmount) (bind (publish 1 0) (lambda (commitment) (bind (pure (+Nat wagerAmount escrowAmount)) (lambda (tmp) (next (action 2 0 (deposit tmp)) (bind (publish 3 1) (lambda (randB) (next (action 4 1 (deposit wagerAmount)) (bind (publish 5 0) (lambda (randA) (bind (pure (digest randA)) (lambda (tmp0) (bind (pure (eq commitment tmp0)) (lambda (tmp1) (next (require tmp1) (bind (pure (bitwise-xor randA randB)) (lambda (tmp2) (bind (pure (bitwise-and tmp2 (t nil))) (lambda (tmp3) (bind (pure (eq tmp3 (nil nil))) (lambda (tmp4) (branch tmp4 (bind (pure (*Nat (nil (t nil)) wagerAmount)) (lambda (tmp5) (bind (pure (+Nat tmp5 escrowAmount)) (lambda (tmp6) (next (action 6 0 (withdraw tmp6)) (pure (quote glow-unit-lit))))))) (bind (pure (*Nat (nil (t nil)) wagerAmount)) (lambda (tmp7) (next (action 7 1 (withdraw tmp7)) (next (action 8 0 (withdraw escrowAmount)) (pure (quote glow-unit-lit)))))))))))))))))))))))))))))|]

coinFlip' :: LurkSource
coinFlip' = [r|(lambda (wagerAmount escrowAmount) (bind (publish 1 0) (lambda (commitment) (bind (pure (+Nat wagerAmount escrowAmount)) (lambda (tmp) (next (action 2 0 (deposit tmp)) (bind (publish 3 1) (lambda (randB) (next (action 4 1 (deposit wagerAmount)) (bind (publish 5 0) (lambda (randA) (bind (pure (digest randA)) (lambda (tmp0) (bind (pure (eq commitment tmp0)) (lambda (tmp1) (next (require tmp1) (bind (pure (bitwise-xor randA randB)) (lambda (tmp2) (bind (pure (bitwise-and tmp2 (t nil))) (lambda (tmp3) (bind (pure (eq tmp3 (nil nil))) (lambda (tmp4) (branch tmp4 (bind (pure (*Nat (nil (t nil)) wagerAmount)) (lambda (tmp5) (bind (pure (+Nat tmp5 escrowAmount)) (lambda (tmp6) (next (action 6 0 (withdraw tmp6)) (pure (quote glow-unit-lit))))))) (bind (pure (*Nat (nil (t nil)) wagerAmount)) (lambda (tmp7) (next (action 7 1 (withdraw tmp7)) (next (action 8 0 (withdraw escrowAmount)) (pure (quote glow-unit-lit)))))))))))))))))))))))))))))|]

jmConsensusState :: ConsensusState
jmConsensusState =
  ConsensusState
    (M.fromList [(LedgerPubKey "Jan",AccountState 100),(LedgerPubKey "Marcin",AccountState 200)])
    (M.fromList
       [])

  
coinFlipConsensusState :: ConsensusState
coinFlipConsensusState =
  ConsensusState
    (M.fromList [(LedgerPubKey "A",AccountState 100),(LedgerPubKey "B",AccountState 200)])
    (M.fromList
       [(nil,
           DeployedContract
             (LMEnv [LedgerPubKey "A" , LedgerPubKey "B"] [GLNat 10 , GLNat 2] coinFlip')
             initialLMState)])

coinFlipConsensusState' :: ConsensusState
coinFlipConsensusState' =
  ConsensusState
    (M.fromList [(LedgerPubKey "A",AccountState 100),(LedgerPubKey "B",AccountState 200)])
    (M.fromList
       [(nil,
           DeployedContract
             (LMEnv [LedgerPubKey "A" , LedgerPubKey "B"] [GLNat 10 , GLNat 2] coinFlip')
             (LMState
                  { _publicValues = [DigestOf (GLNat 7777)]
                  , _stateId = 1
                  }))])
exampleCall :: Call
exampleCall = Call 1 (LedgerPubKey "A") (Publish (DigestOf (GLNat 7777)))


exampleCall' :: Call
exampleCall' = Call 1 (LedgerPubKey "A") (Publish (GLNat 7777))

exampleCall'' :: Call
exampleCall'' = Call 2 (LedgerPubKey "A") (Deposit 12)


-- singleTest :: IO Bool
-- singleTest =
--    fst <$> evalRWST ((verifyCall exampleCall) :: LMS Bool) nil coinFlipConsensusState

-- singleTest' :: IO Bool
-- singleTest' =
--    fst <$> evalRWST ((verifyCall exampleCall'') :: LMS Bool) nil coinFlipConsensusState'


