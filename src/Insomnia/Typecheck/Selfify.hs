{-# LANGUAGE ViewPatterns #-}
module Insomnia.Typecheck.Selfify
       (selfifyModuleType
       , selfifyTypeDefn
       ) where

import Data.Monoid (Monoid(..))

import qualified Unbound.Generics.LocallyNameless as U
import qualified Unbound.Generics.LocallyNameless.Unsafe as UU

import Insomnia.Identifier (Path(..), lastOfPath)
import Insomnia.Types (TypeConstructor(..), TypePath(..))
import Insomnia.Expr (QVar(..))
import Insomnia.TypeDefn (TypeDefn(..), ValConName,
                          ValConPath(..), ValueConstructor(..),
                          ConstructorDef(..))
import Insomnia.ModuleType (ModuleType(..), Signature(..), TypeSigDecl(..))

import Insomnia.Typecheck.Env
import Insomnia.Typecheck.SelfSig (SelfSig(..))
import Insomnia.Typecheck.SigOfModuleType (signatureOfModuleType)

-- | "Selfification" (c.f. TILT) is the process of adding to the current scope
-- a type variable of singleton kind (ie, a module variable standing
-- for a module expression) such that the module variable is given its principal
-- kind (exposes maximal sharing).
selfifyModuleType :: Path -> Signature -> TC SelfSig
selfifyModuleType pmod msig_ =
  case msig_ of
    UnitSig -> return UnitSelfSig
    ValueSig stoch fld ty msig -> do
      let qvar = QVar pmod fld
      selfSig <- selfifyModuleType pmod msig
      return $ ValueSelfSig stoch qvar ty selfSig
    TypeSig fld bnd ->
      U.lunbind bnd $ \((tyId, U.unembed -> tsd), msig) -> do
      let p = TypePath pmod fld
          -- replace the local Con (IdP tyId) way of refering to
          -- this definition in the rest of the signature by
          -- the full projection from the model path.  Also replace the
          -- type constructors
          substVCons = selfifyTypeSigDecl pmod tsd
          substTyCon = [(tyId, TCGlobal p)]
          tsd' = U.substs substTyCon $ U.substs substVCons tsd
          msig' = U.substs substTyCon $ U.substs substVCons msig
      selfSig <- selfifyModuleType pmod msig'
      return $ TypeSelfSig p tsd' selfSig
    SubmoduleSig fld bnd ->
      U.lunbind bnd $ \((modId, U.unembed -> modTy), msig) -> do
        let p = ProjP pmod fld
        (modSig, modK) <- signatureOfModuleType modTy
        modSelfSig' <- selfifyModuleType p modSig
        let msig' = U.subst modId p msig
        selfSig' <- selfifyModuleType pmod msig'
        return $ SubmoduleSelfSig p modSelfSig' modK selfSig'

selfSigToSignature :: SelfSig -> TC Signature
selfSigToSignature UnitSelfSig = return UnitSig
selfSigToSignature (ValueSelfSig stoch (QVar _modulePath fieldName) ty selfSig) = do
  sig <- selfSigToSignature selfSig
  return $ ValueSig stoch fieldName ty sig
selfSigToSignature (TypeSelfSig typePath tsd selfSig) = do
  let (TypePath _ fieldName) = typePath
  freshId <- U.lfresh (U.s2n fieldName)
  sig <- selfSigToSignature selfSig
  return $ TypeSig fieldName (U.bind (freshId, U.embed tsd) sig)
selfSigToSignature (SubmoduleSelfSig path subSelfSig modK selfSig) = do
  let fieldName = lastOfPath path
  freshId <- U.lfresh (U.s2n fieldName)
  subSig <- selfSigToSignature subSelfSig
  sig <- selfSigToSignature selfSig
  let subModTy = SigMT subSig modK
  return $ SubmoduleSig fieldName (U.bind (freshId, U.embed subModTy) sig)

selfifyTypeSigDecl :: Path -> TypeSigDecl -> [(ValConName, ValueConstructor)]
selfifyTypeSigDecl pmod tsd =
  case tsd of
    AbstractTypeSigDecl _k -> mempty
    ManifestTypeSigDecl defn -> selfifyTypeDefn pmod defn
    AliasTypeSigDecl _alias -> mempty

-- | Given the path to a type defintion and the type definition, construct
-- a substitution that replaces unqualified references to the components of
-- the definition (for example the value constructors of an algebraic datatype)
-- by their qualified names with respect to the given path.
selfifyTypeDefn :: Path -> TypeDefn -> [(ValConName, ValueConstructor)]
selfifyTypeDefn _pmod (EnumDefn _) = []
selfifyTypeDefn pmod (DataDefn bnd) = let
  (_, constrDefs) = UU.unsafeUnbind bnd
  cs = map (\(ConstructorDef c _) -> c) constrDefs
  in map (mkSubst pmod) cs
  where
    mkSubst :: Path -> ValConName -> (ValConName, ValueConstructor)
    mkSubst p short =
      let fld = U.name2String short
          long = ValConPath p fld
      in (short, VCGlobal long)
