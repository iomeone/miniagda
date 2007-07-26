module TypeChecker where

import Abstract
import Value
import Signature

import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State

-- reader monad for local environment
-- state monad for global signature
type TypeCheck a = ReaderT Env (StateT Signature Identity) a

runTypeCheck :: Env -> Signature -> TypeCheck a -> (a,Signature)
runTypeCheck env sig tc = runIdentity (runStateT (runReaderT tc env) sig)  
 
typeCheck dl = snd $ runTypeCheck emptyEnv emptySig (typeCheckDecls dl)

typeCheckDecls :: [Declaration] -> TypeCheck ()
typeCheckDecls [] = return ()
typeCheckDecls (d:ds) = do typeCheckDeclaration d
                           typeCheckDecls ds
                           return ()

typeCheckDeclaration :: Declaration -> TypeCheck ()
typeCheckDeclaration (Declaration tsl dl) = do  mapM typeCheckTypeSig (zip tsl dl)
                                                mapM typeCheckDefinition dl  
                                                return ()
typeCheckTypeSig :: (TypeSig,Definition) -> TypeCheck () 
typeCheckTypeSig (a@(TypeSig n t),def) = do sig <- get
                                            put (addSig sig n sigdef)
                                            return ()
    where sigdef = case def of 
                   (DataDef tel _) -> DataSig tel t
                   (FunDef cl) -> FunSig t cl
                   (ConstDef e) -> ConstSig t e

                         
typeCheckDefinition :: Definition -> TypeCheck ()
typeCheckDefinition (DataDef tl cs) = do mapM typeCheckConstructor cs
                                         return ()

typeCheckDefinition (FunDef cls) = return ()
typeCheckDefinition (ConstDef e) = return ()

typeCheckConstructor :: Constructor -> TypeCheck ()
typeCheckConstructor (TypeSig n e) = do sig <- get
                                        put (addSig sig n (ConSig e)) 
                                        return ()
                            
---- Pattern Matching ----

matches :: Pattern -> Val -> Bool
matches p v = case (p,v) of
                (VarP x,_) -> True
                (ConP x [],VCon y) -> x == y
                (ConP x pl,VApp (VCon y) vl) -> x == y && matchesList pl vl
                (WildP ,_) -> True
                (SuccP _,_) -> matchesSucc p v
                _ -> False
                

matchesSucc :: Pattern -> Val -> Bool
matchesSucc p v = case (p,v) of
                    (SuccP (VarP x),VInfty) -> True
                    (SuccP (VarP x),VSucc v2) -> True
                    (SuccP p2,VSucc v2) -> matchesSucc p2 v2
                    _ -> False

matchesList :: [Pattern] -> [Val] -> Bool
matchesList [] [] = True
matchesList (p:pl) (v:vl) = matches p v && matchesList pl vl
matchesList _ _ = False
{-
matchesList x y = error $ "Error matchesList " ++ show x ++ " , " ++ show y 
-}

upPattern :: Env -> Pattern -> Val -> Env
upPattern env p v = case (p,v) of
                      (VarP x,_) -> update env x v
                      (ConP x [],VCon y) -> env
                      (ConP x pl,VApp (VCon y) vl) -> upPatterns env pl vl
                      (WildP,_) -> env
                      (SuccP _,_) -> upSuccPattern env p v

upSuccPattern :: Env -> Pattern -> Val -> Env
upSuccPattern env p v = case (p,v) of
                      (SuccP (VarP x),VInfty) -> update env x v
                      (SuccP (VarP x),VSucc v2) -> update env x v2
                      (SuccP p2,VSucc v2) -> upSuccPattern env p2 v2

upPatterns :: Env -> [Pattern] -> [Val] -> Env
upPatterns env [] [] = env
upPatterns env (p:pl) (v:vl) = let env' = upPattern env p v in
                               upPatterns env' pl vl


matchDef :: Signature -> Env -> Name -> [Val] -> Val
matchDef sig env n vl = 
    case lookupSig sig n of
      (FunSig t cl) -> matchClauses n sig env cl vl 
      _ -> VApp (VDef n) vl   

matchClauses :: Name -> Signature -> Env -> [Clause] -> [Val] -> Val
matchClauses n sig env cl vl = loop cl
    where loop [] = error $ n ++ ": no function clause matches " ++ show vl
                    ++ "\n Clauses: " ++ show cl 
{-
                    ++ "\n Environment: " ++ show env
                    ++ "\n Signature: " ++ show sig 
 -}
          loop  ((Clause (LHS pl) rhs) : cl) = 
              case matchClause n sig env pl rhs vl of
                Nothing -> loop cl
                Just v -> v

matchClause :: Name -> Signature -> Env -> [Pattern] -> RHS -> [Val] -> Maybe Val
matchClause n sig env [] (RHS e) vl = Just (app sig (eval sig env e) vl)
matchClause n sig env (p:pl) rhs (v:vl) = 
    if (matches p v) then 
        matchClause n sig (upPattern env p v) pl rhs vl
    else
        Nothing 
matchClause n sig env pl _ [] = error $ "matchClause " ++ n 
-- ++ (show pl) ++ "\n" ++ (show vl) 
  ++ " (too few arguments) "

--- Interpreter


app :: Signature -> Val -> [Val] -> Val
app sig u v = case (u,v) of
            (_,[]) -> u
            (VClos env (Lam (TBind x _) e), v0:vs) -> 
                app sig (eval sig (update env x v0) e) vs
            (VDef n,_) -> matchDef sig [] n v
            _ -> VApp u v

vsucc :: Val -> Val
vsucc VInfty = VInfty
vsucc v = VSucc v

eval :: Signature -> Env -> Expr -> Val
eval sig env e = case e of
               Set -> VSet
               Infty -> VInfty
               Succ e -> vsucc (eval sig env e)
               Size -> VSize
               Con n -> VCon n
               App e1 e2 -> app sig (eval sig env e1) (map (eval sig env) e2)
               Def n -> VDef n
               Const n -> let (ConstSig t e) = lookupSig sig n in eval sig env e 
               Var y -> lookupEnv env y
               _ -> VClos env e



whnf :: Signature -> Val -> Val
whnf sig v = case v of 
               VApp u w -> app sig (whnf sig u) (map (whnf sig) w)
               VClos env e -> eval sig env e
               _ -> v



--- equality

eqVal :: Signature -> Int -> Val -> Val -> Bool
eqVal sig k u1 u2 = case (whnf sig u1, whnf sig u2) of
                      (VSet,VSet) -> True
                      (VGen k1,VGen k2) -> k1 == k2
                      (VSize,VSize) -> True
                      (VInfty,VInfty) -> True
                      (VSucc v1,VSucc v2) -> eqVal sig k v1 v2
                      (VApp v1 vl1,VApp v2 vl2) -> eqVal sig k v1 v2 && eqVals sig k vl1 vl2
                      _ -> False
                  
eqVals :: Signature -> Int -> [Val] -> [Val] -> Bool
eqVals sig k vl1 vl2 = all (\(x,y) -> eqVal sig k x y) (zip vl1 vl2)



eqT :: Signature -> Int -> Val -> Val -> Bool
eqT sig k t1 t2 = case (t1,t2) of
                  (VSet,VSet) -> True
                  _ -> error "eqT"


eqV :: Signature -> Int -> Val -> Val -> Val -> Bool
eqV sig k t u v = True

infEq :: Signature -> Int -> Val -> Val -> Val
infEq sig k t uv = VSet

-- type checking

checkExpr :: Signature -> Int -> Env -> Expr -> Val -> Bool
checkExpr _ _ _ _ _ = True

inferExpr :: Signature -> Int -> Env -> Expr -> Val
inferExpr _ _ _ _ = VSet

checkType :: Signature -> Int -> Env -> Expr -> Bool
checkType sig k env ty = checkExpr sig k env ty VSet

--

checkDecl :: Signature -> Declaration -> Bool
checkDecl sig decl = True


checkDefinition :: Signature -> Definition -> Bool
checkDefinition sig (DataDef tel cl) = True
checkDefinition sig (FunDef cl) = True
checkDefinition sig (ConstDef e) = True
 




