{-# LANGUAGE
      MultiParamTypeClasses, FlexibleContexts,
      ViewPatterns,
      DeriveDataTypeable, DeriveGeneric
  #-}
module Insomnia.Module where

import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Unbound.Generics.LocallyNameless

import Insomnia.Identifier
import Insomnia.Types
import Insomnia.TypeDefn
import Insomnia.ModuleType

import Insomnia.Common.Stochasticity
import Insomnia.Common.Telescope
import Insomnia.Expr (TabulatedFun, Function, Expr)

data ModuleExpr =
  ModuleStruct !Module -- module specified here
  | ModuleModel !ModelExpr -- model suspension
  | ModuleSeal !ModuleExpr !ModuleType -- generative sealing
  | ModuleAssume !ModuleType    -- module assumed to exist.
  | ModuleId !Path       -- previously named module
  | ModuleFun (Bind (Telescope (FunctorArgument ModuleType)) ModuleExpr)
  | ModuleApp !Path ![Path] -- functor application
  deriving (Show, Typeable, Generic)

data ModelExpr =
  ModelStruct !Module  -- model specified here
  | ModelId !Path      -- previously named model
    -- | local X ~ M in M' : Mt Note that X is not bound in Mt.  The
    -- annotation is required due to the "avoidance problem": we could
    -- try to naively infer a principal signature and issue an error
    -- if X is mentioned, but in general there does not exist a most
    -- general signature for M' that doesn't mention X.
  | ModelLocal !Module !ModelExpr !ModuleType -- must annotate with sig.
  deriving (Show, Typeable, Generic)

-- A single module.
data Module = Module { moduleDecls :: [Decl] }
              deriving (Show, Typeable, Generic)

-- | A declaration
data Decl =
  ValueDecl !Field !ValueDecl -- ^ declaration of a value
  | ImportDecl !Path          -- ^ import definitions from the given path
  | TypeDefn !Field !TypeDefn   -- ^ generative construction of new types
  | TypeAliasDefn !Field !TypeAlias -- ^ a type alias definition
  | SubmoduleDefn !Field !ModuleExpr -- ^ a nested module definition
  | SampleModuleDefn !Field !ModuleExpr -- ^ sample a module from a model
  deriving (Show, Typeable, Generic)

data ValueDecl =
  FunDecl !Function     -- ^ function definition "fun f = ..."
  | ParameterDecl !Expr -- ^ parameter definition "parameter x = ... "
  | ValDecl !Expr   -- ^ a value definition "val x = ..." (sugar for "val x ~ = ireturn ...")
  | SampleDecl !Expr -- ^ a sampled value definition "val x ~ ..."
  | TabulatedSampleDecl !TabulatedFun -- ^ a tabulated function definition "forall x in f x ~ e"
  | SigDecl !Stochasticity !Type   -- ^ a function signature "[parameter] sig f :: A -> B"
  deriving (Show, Typeable, Generic)

instance Alpha ModuleExpr
instance Alpha ModelExpr
instance Alpha Module
instance Alpha Decl
instance Alpha ValueDecl

instance Subst Path ModuleExpr
instance Subst Path ModelExpr
instance Subst Path Module
instance Subst Path Decl
instance Subst Path ValueDecl

instance Subst TypeConstructor ModuleExpr
instance Subst TypeConstructor ModelExpr
instance Subst TypeConstructor Module
instance Subst TypeConstructor Decl
instance Subst TypeConstructor ValueDecl

instance Subst ValueConstructor ModuleExpr
instance Subst ValueConstructor ModelExpr
instance Subst ValueConstructor Module
instance Subst ValueConstructor Decl
instance Subst ValueConstructor ValueDecl

