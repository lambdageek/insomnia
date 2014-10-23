{-# LANGUAGE TemplateHaskell, OverloadedStrings,
      FlexibleInstances, MultiParamTypeClasses
  #-}
-- | The typechecking environment.
--
-- This module defines the typing context and the
-- typechecking monad.
module Insomnia.Typecheck.Env where

import Control.Lens

import Control.Monad.Trans.Class (lift)
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.Trans.Reader (ReaderT (..))
import Control.Monad.Error.Class (MonadError(..))

import Data.Format (Format(..))
import qualified Data.Format as F
import Data.List (foldl')
import qualified Data.Map as M
import Data.Monoid (Monoid(..), (<>))

import qualified Unbound.Generics.LocallyNameless as U
import Unbound.Generics.LocallyNameless.LFresh (LFreshMT, runLFreshMT)

import Insomnia.Except (Except, runExcept)

import Insomnia.Identifier
import Insomnia.Types
import Insomnia.Expr (Var, QVar)
import Insomnia.ModelType (TypeSigDecl, Signature)

import Insomnia.Unify (MonadUnificationExcept(..),
                       UVar,
                       UnificationT,
                       runUnificationT)

import Insomnia.Pretty (Pretty(..), ppDefault, text, vcat, fsep, punctuate)


-- | Type checker errors
newtype TCError = TCError { getTCError :: F.Doc }

instance Format TCError where
  format = format . getTCError

type ConstructorArgs = (U.Bind [KindedTVar] [Type])

-- each constructor C of algebraic datatype D has the form:
--  ∀ (α₁ ∷ K₁, … αᵢ ∷ Kᵢ) . T₁ → T₂ → ⋯ → D α₁ ⋯ αᵢ
-- (if we add GADTs, there will also be existential β vars and
-- equality constraints.  In any case, D will always be applied to exactly
-- the αs and we don't bother storing the whole application.  Just the head
-- data constructor D.)
data AlgConstructor =
  AlgConstructor {
    _algConstructorArgs :: ConstructorArgs
    , _algConstructorDCon :: Con
    }
  deriving (Show)
           
data AlgType =
  AlgType {
    _algTypeParams :: [Kind] -- ^ the ADT is parametric, having kind κ1→⋯→κN→⋆
    , _algTypeCons :: [Con] -- ^ the names of the constructors in this kind.
    }

-- | Types that arise as a result of checking a declaration.  Each
-- declaration gives rise to a new type that is distinct even from
-- other declarations that appear structurally equivalent.  (Formally
-- these may be modeled by singleton kinds or by definitions in a
-- typing context.)
data GenerativeType =
  AlgebraicType !AlgType -- ^ an (AlgebraicType κs) declares a type of kind κ1 → ⋯ → κN → ⋆
  | EnumerationType !Nat -- ^ a finite enumeration type of N elements
  | AbstractType !Kind -- ^ an abstract type with no (visible) definition.
--   | RecordType Rows -- ^ a record type with the given rows

-- | A selfified signature.  After selfification, all references to
-- declared types and values within the model are referenced
-- by their fully qualified name with respect to the path to the model.
data SelfSig =
  UnitSelfSig
  | ValueSelfSig QVar Type SelfSig
  | TypeSelfSig Con TypeSigDecl SelfSig

$(makeLenses ''AlgConstructor)
$(makeLenses ''AlgType)
  
-- | Typechecking environment
data Env = Env {
  _envSigs :: M.Map Identifier Signature -- ^ signatures
  , _envDCons :: M.Map Con GenerativeType -- ^ data types
  , _envCCons :: M.Map Con AlgConstructor -- ^ value constructors
  , _envGlobals :: M.Map QVar Type      -- ^ declared global vars
  , _envGlobalDefns :: M.Map QVar ()    -- ^ defined global vars
  , _envTys :: M.Map TyVar Kind        -- ^ local type variables
  , _envLocals :: M.Map Var Type       -- ^ local value variables
  , _envVisibleSelector :: M.Map Var () -- ^ local vars that may be used as indices of tabulated functions.  (Come into scope in "forall" expressions)
  }


$(makeLenses ''Env)

instance Pretty AlgConstructor where
  pp = text . show

instance Pretty AlgType where
  pp alg = vcat ["params"
                , fsep $ punctuate "," (map pp (alg^.algTypeParams))
                , "constructors"
                , fsep $ punctuate "|" (map pp (alg^.algTypeCons))
                ]

instance Pretty GenerativeType where
  pp (AlgebraicType alg) = pp alg
  pp (EnumerationType n) = pp n
  pp (AbstractType k) = pp k


instance Pretty Env where
  pp env = vcat [ "sigs", pp (env^.envSigs)
                , "dcons", pp (env^.envDCons)
                , "ccons", pp (env^.envCCons)
                , "globals", pp (env^.envGlobals)
                , "global defns", pp (env^.envGlobalDefns)
                                  -- TODO: the rest of the env
                ]

-- | The empty typechecking environment
emptyEnv :: Env
emptyEnv = Env mempty mempty mempty mempty mempty mempty mempty mempty

-- | Base environment with builtin types.
baseEnv :: Env
baseEnv = emptyEnv
          & (envDCons . at conArrow) .~ Just (AlgebraicType algArrow)
          & (envDCons . at conDist) .~ Just (AlgebraicType algDist)
          & (envDCons . at conInt) .~ Just (AlgebraicType algInt)
          & (envDCons . at conReal) .~ Just (AlgebraicType algReal)

builtinCon :: String -> Con
builtinCon = Con . IdP . U.s2n

-- | Base data constructors
conArrow :: Con
conArrow = builtinCon "->"

conDist :: Con
conDist = builtinCon "Dist"

conInt :: Con
conInt = builtinCon "Int"

conReal :: Con
conReal = builtinCon "Real"

algArrow :: AlgType
algArrow = AlgType [KType, KType] []

algDist :: AlgType
algDist = AlgType [KType] []

algInt :: AlgType
algInt = AlgType [] []

algReal :: AlgType
algReal = AlgType [] []

functionT :: Type -> Type -> Type
functionT t1 t2 = TC conArrow `TApp` t1 `TApp` t2

functionT' :: [Type] -> Type -> Type
functionT' [] _tcod = error "expected at least one domain type"
functionT' [tdom] tcod = functionT tdom tcod
functionT' (tdom:tdoms) tcod = functionT tdom (functionT' tdoms tcod)

distT :: Type -> Type
distT tsample = TC conDist `TApp` tsample

intT :: Type
intT = TC conInt

realT :: Type
realT = TC conReal


-- | The typechecking monad sand unification
type TCSimple = ReaderT Env (LFreshMT (Except TCError))

-- | The typechecking monad
type TC = UnificationT Type TCSimple

-- instance MonadUnificationExcept Type TCSimple
instance MonadUnificationExcept TypeUnificationError Type (ReaderT Env (LFreshMT (Except TCError))) where
  throwUnificationFailure = throwError . TCError . formatErr

-- | Run a typechecking computation
runTC :: TC a -> Either TCError (a, M.Map (UVar Type) Type)
runTC comp =
  runExcept $ runLFreshMT $ runReaderT (runUnificationT comp) baseEnv

-- | Given a value constructor c, return its type as a polymorphic function
--   (that is, ∀ αs . T1(αs) → ⋯ → TN(αs) → D αs)
mkConstructorType :: AlgConstructor -> TC Type
mkConstructorType constr = 
  -- XX could do unsafeBunbind here for working under the binder.
  U.lunbind (constr^.algConstructorArgs) $ \ (tvks, targs) -> do
  let tvs = map (TV . fst) tvks
      d = constr^.algConstructorDCon
      -- data type applied to the type variables - D α1 ⋯ αK
      dt = foldl' TApp (TC d) tvs
      -- arg1 → (arg2 → ⋯ (argN → D αs))
      ty = foldr functionT dt targs
  -- ∀ αs . …
  return $ go ty tvks
  where
    go t [] = t
    go t (tvk:tvks) = go (TForall (U.bind tvk t)) tvks

-- | Look up info about a datatype
lookupDCon :: Con -> TC GenerativeType
lookupDCon d = do
  m <- view (envDCons . at d)
  case m of
    Just k -> return k
    Nothing -> typeError $ "no data type " <> formatErr d

lookupCCon :: Con -> TC AlgConstructor
lookupCCon c = do
  m <- view (envCCons . at c)
  case m of
    Just constr -> return constr
    Nothing -> typeError $ "no datatype defines a constructor " <> formatErr c

-- | Lookup the kind of a type variable
lookupTyVar :: TyVar -> TC Kind
lookupTyVar tv = do
  m <- view (envTys . at tv)
  case m of
    Just k -> return k
    Nothing -> typeError $ "no type variable " <> formatErr tv

lookupGlobal :: QVar -> TC (Maybe Type)
lookupGlobal v = view (envGlobals . at v)

lookupLocal :: Var -> TC (Maybe Type)
lookupLocal v = view (envLocals . at v)

lookupVar :: Var -> TC (Maybe Type)
lookupVar v = lookupLocal v
  -- TODO: does this make sense?  It should now be the case that
  -- all global variable refernces are turned into QVars before we
  -- get going.
  -- do
  -- tl <- First <$> lookupLocal v
  -- tg <- First <$> lookupGlobal v
  -- return $ getFirst (tl <> tg)

-- | Checks tht the given identifier is bound in the context to a
-- signature.
lookupModelType :: Identifier -> TC Signature
lookupModelType ident = do
  mmsig <- view (envSigs . at ident)
  case mmsig of
    Just msig -> return msig
    Nothing -> typeError ("no model type " <> formatErr ident
                          <> " in scope")

-- | Extend the data type environment by adding the declaration
-- of the given data type with the given kind
extendDConCtx :: Con -> GenerativeType -> TC a -> TC a
extendDConCtx dcon k = local (envDCons . at dcon ?~ k)

extendConstructorsCtx :: [(Con, AlgConstructor)] -> TC a -> TC a
extendConstructorsCtx cconstrs =
  local (envCCons %~ M.union (M.fromList cconstrs))

extendValueDefinitionCtx :: QVar -> TC a -> TC a
extendValueDefinitionCtx v =
  local (envGlobalDefns %~ M.insert v ())

-- | @extendTyVarCtx a k comp@ Extend the type environment of @comp@
-- with @a@ having the kind @k@.
extendTyVarCtx :: TyVar -> Kind -> TC a -> TC a
extendTyVarCtx a k =
  -- no need for U.avoid since we used U.lunbind when we brough the
  -- variable into scope.
  local (envTys . at a ?~ k)

-- | Extend the type environment with all the given type variables
-- with the given kinds.  Assumes the variables are distinct.
-- Does not add to the avoid set because we must have already called U.lunbind.
extendTyVarsCtx :: [(TyVar, Kind)] -> TC a -> TC a
extendTyVarsCtx vks = local (envTys %~ M.union (M.fromList vks))

-- | Extend the local variables environment by adding the given
-- variable (assumed to be free and fresh) with the given type (which may be
-- a UVar)
extendLocalCtx :: Var -> Type -> TC a -> TC a
extendLocalCtx v t = local (envLocals . at v ?~ t)

extendLocalsCtx :: [(Var, Type)] -> TC a -> TC a
extendLocalsCtx vts = local (envLocals %~ M.union (M.fromList vts))

-- | Make the given vars be the only legal selectors when runnning
-- the given computation
settingVisibleSelectors :: [Var] -> TC a -> TC a
settingVisibleSelectors vs =
  local (envVisibleSelector .~ vsMap)
  where
    vsMap = M.fromList (map (\k -> (k, ())) vs)

guardDuplicateDConDecl :: Con -> TC ()
guardDuplicateDConDecl dcon = do
  mdata <- view (envDCons . at dcon)
  case mdata of
    Nothing -> return ()
    Just _ -> typeError ("data type "
                         <> formatErr dcon
                         <> " is already defined")

guardDuplicateCConDecl :: Con -> TC ()
guardDuplicateCConDecl ccon = do
  mcon <- view (envCCons . at ccon)
  case mcon of
    Nothing -> return ()
    Just _ -> typeError ("value constructor "
                         <> formatErr ccon
                         <> " is already defined")

ensureNoDefn :: QVar -> TC ()
ensureNoDefn v = do
  m <- view (envGlobalDefns . at v)
  case m of
    Just () -> typeError ("duplicate defintion of " <> formatErr v)
    Nothing -> return ()


-- | Format some thing for error reporting.
formatErr :: (Pretty a) => a -> F.Doc
formatErr = format . ppDefault

-- | Throw some kind of type checking error
throwTCError :: TCError -> TC a
throwTCError = lift . lift . throwError

-- | Throw a type error with the given message.
typeError :: F.Doc -> TC a
typeError msg = do
  env <- ask
  throwTCError $ TCError ("type error: " <> msg
                          <> "\nEnvironment:\n"
                          <> formatErr env)

-- | Throw an error with the given message indicating that
-- part of the typechecker is unimplemented.
unimplemented :: F.Doc -> TC a
unimplemented msg =
  throwTCError . TCError $ "typecheck unimplemented: " <> msg