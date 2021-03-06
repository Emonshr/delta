{-# LANGUAGE ScopedTypeVariables #-}

module TypeInfer where

import qualified Propagate as Prop
import Propagate (queryVar, ChangeStatus(..))

import Unify
import OrderedPair
import DirectedGraph
import TopoSort

import CollectionUtils (transferValues)

import qualified ComplementSet as CSet
import ComplementSet (ComplementSet (..))

import qualified Data.Map as Map
import Data.Map (Map)

import qualified Data.Set as Set
import Data.Set (Set)

import Control.Monad (foldM, join, when)
import Data.Maybe (fromMaybe, fromJust)
import Data.Bifunctor (first, second)

data Relation = Equality | Inequality Inequality deriving (Eq, Ord, Show)

data Formulation = AppOf | TupleOf deriving (Eq, Ord, Show)

data Constraint var atom inter
  = BoundConstraint var (Type atom inter)
  | RelationConstraint var Relation var
  | FormulationConstraint var Formulation var var
  | FuncConstraint var (var, var, var)
  | InteractionConstraint var inter [var] -- This is an *inequality* constraint of the form i<x> ≤ v
  | InteractionDifferenceConstraint var (Set inter) var
  deriving (Eq, Ord, Show)

data InferenceError var err atom inter
  = InferenceError
    { errorConstraint :: Constraint var atom inter
    , errorContent :: TypeError err atom inter
    }
  | FormMismatch var Formulation (Maybe (Type atom inter))
  | NotFunction var (Maybe (Type atom inter))
  | RecursiveType -- This should probably have some useful data attached to it
  | NotInteraction var (Maybe (Type atom inter))
  | InteractionCantContain var (Set inter) (Maybe (Type atom inter))
  deriving (Eq, Ord, Show)

data Problem var err atom inter = Problem
  { problemConstraints :: [Constraint var atom inter]
  , problemAtomUnifier :: Unifier err atom
  }

type Solution var err atom inter = Either (InferenceError var err atom inter) (var -> Maybe (Type atom inter))

data ConsolidatedConstraints var err atom inter = ConsolidatedConstraints
  { boundConstraints :: Map var (Type atom inter)
  , relationConstraints :: Map (OrderedPair var) Relation
  , formulationConstraints :: [(var, Formulation, var, var)]
  , funcConstraints :: [(var, (var, var, var))]
  , interactionConstraints :: [(var, inter, [var])]
  , interactionDifferenceConstraints :: [(var, Set inter, var)]
  }

emptyConstraints :: ConsolidatedConstraints var err atom inter
emptyConstraints = ConsolidatedConstraints Map.empty Map.empty [] [] [] []

relationConjunction :: Relation -> Relation -> Relation
relationConjunction r1 r2 =
  if r1 == r2
    then r1
    else Equality

flipRelation :: Relation -> Relation
flipRelation Equality = Equality
flipRelation (Inequality LTE) = Inequality GTE
flipRelation (Inequality GTE) = Inequality LTE

data StructuralSizeRelation var = var `StructurallyLargerThan` var

structuralSizeRelations :: Constraint var atom inter -> [StructuralSizeRelation var]
structuralSizeRelations (BoundConstraint _ _) = []
structuralSizeRelations (RelationConstraint _ _ _) = []
structuralSizeRelations (FormulationConstraint whole _ part1 part2) =
  [ whole `StructurallyLargerThan` part1
  , whole `StructurallyLargerThan` part2
  ]
structuralSizeRelations (FuncConstraint func (arg, inter, ret)) =
  [ func `StructurallyLargerThan` arg
  , func `StructurallyLargerThan` inter
  , func `StructurallyLargerThan` ret
  ]
structuralSizeRelations (InteractionConstraint var _ params) =
  map (var `StructurallyLargerThan`) params
structuralSizeRelations (InteractionDifferenceConstraint var inters restVar) =
  if Set.null inters
    then []
    else [var `StructurallyLargerThan` restVar]

impliesIllegalRecursiveTypes :: (Ord var) => [Constraint var atom inter] -> Bool
impliesIllegalRecursiveTypes constraints =
  let
    structuralRelations = concatMap structuralSizeRelations constraints
    consolidatedStructuralRelations =
      outgoingEdges $
      buildDirectedGraph $
      map
        (\(a `StructurallyLargerThan` b) -> a `EdgeTo` b)
        structuralRelations
  in case topoSort consolidatedStructuralRelations of
    Just _ -> False
    Nothing -> True

splitFormulation :: Formulation -> Maybe (Type atom inter) -> Maybe (Maybe (Type atom inter), Maybe (Type atom inter))

splitFormulation AppOf (Just (App appHead param)) = Just (appHead, param)
splitFormulation AppOf (Just Never) = Just (Just Never, Nothing)

splitFormulation TupleOf (Just (Tuple _ tupleFst tupleSnd)) = Just (tupleFst, tupleSnd)
splitFormulation TupleOf (Just Never) = Just (Nothing, Nothing)

splitFormulation _ (Just _) = Nothing
splitFormulation _ Nothing = Just (Nothing, Nothing)

joinFormulation :: Formulation -> (Maybe (Type atom inter), Maybe (Type atom inter)) -> Maybe (Type atom inter)
joinFormulation AppOf = Just . uncurry App
joinFormulation TupleOf = Just . uncurry (Tuple (SpecialBounds True True))

funcComponents :: Maybe (Type atom inter) -> Maybe (SpecialBounds, Maybe (Type atom inter), Maybe (Type atom inter), Maybe (Type atom inter))
funcComponents Nothing = Just (SpecialBounds False False, Nothing, Nothing, Nothing)
funcComponents (Just (Func sBounds arg inter ret)) = Just (sBounds, arg, inter, ret)
funcComponents (Just _) = Nothing

interactionComponents :: Maybe (Type atom inter) -> Maybe (InteractionLower atom inter, InteractionUpper inter)
interactionComponents Nothing = Just (Map.empty, Excluded Set.empty)
interactionComponents (Just (Interaction lo hi)) = Just (lo, hi)
interactionComponents (Just _) = Nothing

markError :: Constraint var atom inter -> Either (TypeError err atom inter) a -> Either (InferenceError var err atom inter) a
markError constraint = first (InferenceError constraint)

insertMaybe :: (Ord k) => k -> Maybe a -> Map k a -> Map k a
insertMaybe k (Just val) = Map.insert k val
insertMaybe k Nothing = Map.delete k

solve :: forall var err atom inter. (Ord var, Eq atom, Ord inter) => Problem var err atom inter -> Solution var err atom inter
solve problem = do
  when (impliesIllegalRecursiveTypes (problemConstraints problem)) $ Left RecursiveType

  let
    unifier = liftAtomUnifier $ problemAtomUnifier problem

    mergeUpdates ::
      var ->
      Maybe (Type atom inter) ->
      Maybe (Type atom inter) ->
      Either (InferenceError var err atom inter) (Maybe (Type atom inter))

    mergeUpdates var bound1 bound2 =
      let constraint = RelationConstraint var Equality var
      in markError constraint $ unifyEQ unifier bound1 bound2

    includeConstraint ::
      ConsolidatedConstraints var err atom inter ->
      Constraint var atom inter ->
      Either
        (InferenceError var err atom inter)
        (ConsolidatedConstraints var err atom inter)

    includeConstraint constraints c@(BoundConstraint var bound) = do
      let oldBoundConstraints = boundConstraints constraints
      let oldBound = Map.lookup var oldBoundConstraints
      newBound <- markError c $ unifyEQ unifier (Just bound) oldBound
      let newBoundConstraints = insertMaybe var newBound oldBoundConstraints
      return constraints { boundConstraints = newBoundConstraints }

    includeConstraint constraints (RelationConstraint var1 rel var2) =
      let
        oldRelations = relationConstraints constraints
        (ordered, flipped) = orderedPair' var1 var2
        normalizedRel = case flipped of
          DidNotFlip -> rel
          DidFlip -> flipRelation rel
        oldRelation = Map.lookup ordered oldRelations
        newRelation = fromMaybe normalizedRel $ fmap (relationConjunction normalizedRel) oldRelation
        newRelations = Map.insert ordered newRelation oldRelations
      in
        Right constraints { relationConstraints = newRelations }

    includeConstraint constraints (FormulationConstraint var1 form var2 var3) =
      let
        oldFormulations = formulationConstraints constraints
        newFormulations = (var1, form, var2, var3) : oldFormulations
      in
        Right constraints { formulationConstraints = newFormulations }

    includeConstraint constraints (FuncConstraint var1 (argVar, interVar, retVar)) =
      let
        oldFuncConstraints = funcConstraints constraints
        newFuncConstraints = (var1, (argVar, interVar, retVar)) : oldFuncConstraints
      in
        Right constraints { funcConstraints = newFuncConstraints }

    includeConstraint constraints (InteractionConstraint var inter params) =
      let
        oldInteractionConstraints = interactionConstraints constraints
        newInteractionConstraints = (var, inter, params) : oldInteractionConstraints
      in
        Right constraints { interactionConstraints = newInteractionConstraints }

    includeConstraint constraints (InteractionDifferenceConstraint var inters restVar) =
      let
        oldInteractionDifferenceConstraints = interactionDifferenceConstraints constraints
        newInteractionDifferenceConstraints = (var, inters, restVar) : oldInteractionDifferenceConstraints
      in
        Right constraints { interactionDifferenceConstraints = newInteractionDifferenceConstraints }

    enforceRelation ::
      (var, var) ->
      Relation ->
      Prop.ConstraintEnforcer
        var
        (Maybe (Type atom inter))
        (InferenceError var err atom inter)

    enforceRelation (var1, var2) Equality =
      go <$> queryVar var1 <*> queryVar var2 where
        go (_, Unchanged) (_, Unchanged) = Right []
        go (bound1, Changed) (_, Unchanged) = Right [(var2, bound1)]
        go (_, Unchanged) (bound2, Changed) = Right [(var1, bound2)]
        go (bound1, Changed) (bound2, Changed) = do
          bound <- markError (RelationConstraint var1 Equality var2) $
            unifyEQ unifier bound1 bound2
          return [(var1, bound), (var2, bound)]

    enforceRelation (var1, var2) (Inequality GTE) = enforceRelation (var2, var1) (Inequality LTE)

    enforceRelation (var1, var2) (Inequality LTE) =
      go <$> queryVar var1 <*> queryVar var2 where
        constraint = RelationConstraint var1 (Inequality LTE) var2
        go (_, Unchanged) (_, Unchanged) = Right []
        go (bound1, Changed) (bound2, Unchanged) = do
            bound2' <- markError constraint $ unifyAsym unifier LTE bound1 bound2
            return [(var2, bound2')]
        go (bound1, Unchanged) (bound2, Changed) = do
          bound1' <- markError constraint $ unifyAsym unifier GTE bound2 bound1
          return [(var1, bound1')]
        go (bound1, Changed) (bound2, Changed) = do
          (bound1', bound2') <- markError constraint $ unifyLTE unifier bound1 bound2
          return [(var1, bound1'), (var2, bound2')]

    enforceEQ ::
      (Maybe (Type atom inter), ChangeStatus) ->
      (Maybe (Type atom inter), ChangeStatus) ->
      Either (TypeError err atom inter) (Maybe (Type atom inter))

    enforceEQ (bound, Unchanged) (_, Unchanged) = Right bound
    enforceEQ (bound1, Changed) (_, Unchanged) = Right bound1
    enforceEQ (_, Unchanged) (bound2, Changed) = Right bound2
    enforceEQ (bound1, Changed) (bound2, Changed) = unifyEQ unifier bound1 bound2

    enforceFormulation ::
      (var, Formulation, var, var) ->
      Prop.ConstraintEnforcer
        var
        (Maybe (Type atom inter))
        (InferenceError var err atom inter)

    enforceFormulation (wholeVar, form, var1, var2) =
      let
        constraint = FormulationConstraint wholeVar form var1 var2
        go (_, Unchanged) (_, Unchanged) (_, Unchanged) = Right []
        go (wholeBound, wholeChange) (bound1, change1) (bound2, change2) = do
          (part1, part2) <- case splitFormulation form wholeBound of
            Just parts -> Right parts
            Nothing -> Left $ FormMismatch wholeVar form wholeBound
          part1' <- markError constraint $
            enforceEQ (part1, wholeChange) (bound1, change1)
          part2' <- markError constraint $
            enforceEQ (part2, wholeChange) (bound2, change2)
          let
            wholeUpdate =
              if change1 == Changed || change2 == Changed
                then [(wholeVar, joinFormulation form (part1', part2'))]
                else []
            boundUpdates =
              if wholeChange == Changed
                then [(var1, part1'), (var2, part2')]
                else []
          return $ wholeUpdate ++ boundUpdates
      in
        go <$> queryVar wholeVar <*> queryVar var1 <*> queryVar var2

    -- Currently largely redundant with formulation constraints, but will need to be treated
    -- separately when interactions are implemented, so we may as well just separate it now.
    enforceFuncConstraint ::
      (var, (var, var, var)) ->
      Prop.ConstraintEnforcer
        var
        (Maybe (Type atom inter))
        (InferenceError var err atom inter)

    enforceFuncConstraint (funcVar, (argVar, interVar, retVar)) =
      let
        constraint = FuncConstraint funcVar (argVar, interVar, retVar)
        go (_, Unchanged) (_, Unchanged) (_, Unchanged) (_, Unchanged) = Right []
        go (funcBound, funcChange) (argBound, argChange) (interBound, interChange) (retBound, retChange) = do
          (_, argPart, interPart, retPart) <- case funcComponents funcBound of
            Just components -> Right components
            Nothing -> Left $ NotFunction funcVar funcBound
          argPart' <- markError constraint $
            enforceEQ (argPart, funcChange) (argBound, argChange)
          interPart' <- markError constraint $
            enforceEQ (interPart, funcChange) (interBound, interChange)
          retPart' <- markError constraint $
            enforceEQ (retPart, funcChange) (retBound, retChange)
          let
            newFunc = Just $ Func (SpecialBounds True True) argPart' interPart' retPart'
            funcUpdate =
              if argChange == Changed || interChange == Changed || retChange == Changed
                then [(funcVar, newFunc)]
                else []
            boundUpdates =
              if funcChange == Changed
                then [(argVar, argPart'), (interVar, interPart'), (retVar, retPart')]
                else []
          return $ funcUpdate ++ boundUpdates
      in
        go <$> queryVar funcVar <*> queryVar argVar <*> queryVar interVar <*> queryVar retVar

    enforceDifferenceConstraint ::
      (var, Set inter, var) ->
      Prop.ConstraintEnforcer
        var
        (Maybe (Type atom inter))
        (InferenceError var err atom inter)

    enforceDifferenceConstraint (wholeVar, inters, restVar) =
      go <$> queryVar wholeVar <*> queryVar restVar where
        wholeComponents whole =
          case interactionComponents whole of
            Just components -> Right components
            Nothing -> Left $ NotInteraction wholeVar whole

        restComponents rest =
          case interactionComponents rest of
            Just components -> Right components
            Nothing -> Left $ NotInteraction restVar rest

        checkRestDisjoint (restLo, restHi) =
          when (any (`Map.member` restLo) inters || any (`CSet.member` restHi) inters) $
            Left $ InteractionCantContain restVar inters (Just (Interaction restLo restHi))

        constraint = InteractionDifferenceConstraint wholeVar inters restVar

        go (_, Unchanged) (_, Unchanged) = Right []

        go (whole, Changed) (_, Unchanged) = do
          (wholeLo, wholeHi) <- wholeComponents whole
          let (restLo, restHi) = interactionSubtract inters (wholeLo, wholeHi)
          return [(restVar, Just $ Interaction restLo restHi)]

        go (whole, Unchanged) (rest, Changed) = do
          (wholeLo, wholeHi) <- wholeComponents whole
          (restLo, restHi) <- restComponents rest
          checkRestDisjoint (restLo, restHi)
          let wholeLo' = transferValues restLo wholeLo
          let wholeHi' = CSet.union wholeHi restHi
          return [(wholeVar, Just $ Interaction wholeLo' wholeHi')]

        go (whole, Changed) (rest, Changed) = do
          (wholeLo, wholeHi) <- wholeComponents whole
          let (wholeSubLo, wholeSubHi) = interactionSubtract inters (wholeLo, wholeHi)
          (restLo', restHi') <- restComponents =<< (markError constraint $
            unifyEQ unifier (Just (Interaction wholeSubLo wholeSubHi)) rest)
          checkRestDisjoint (restLo', restHi')
          let wholeLo' = Map.unionWith const restLo' wholeLo
          let wholeHi' = CSet.intersection wholeHi (CSet.union (Included inters) restHi')
          return
            [ (wholeVar, Just $ Interaction wholeLo' wholeHi')
            , (restVar, Just $ Interaction restLo' restHi')
            ]

    enforceInteractionConstraint ::
      (var, inter, [var]) ->
      Prop.ConstraintEnforcer
        var
        (Maybe (Type atom inter))
        (InferenceError var err atom inter)

    enforceInteractionConstraint (wholeVar, inter, paramVars) =
      go <$> queryVar wholeVar <*> traverse (fmap fst . queryVar) paramVars where
        constraint = InteractionConstraint wholeVar inter paramVars

        wholeComponents whole =
          case interactionComponents whole of
            Just components -> Right components
            Nothing -> Left $ NotInteraction wholeVar whole

        go (whole, Unchanged) params = do
          (wholeLo, wholeHi) <- wholeComponents whole
          let wholeLo' = Map.insert inter params wholeLo
          return [(wholeVar, Just $ Interaction wholeLo' wholeHi)]

        go (whole, Changed) params = do
          {- TODO: this could benefit from an optimization which takes into account the change
          status of each param and avoids the expensive symmetric equality unification step when
          possible.
          -}
          let syntheticLesser = Interaction (Map.singleton inter params) (CSet.Excluded Set.empty)
          whole' <- fmap snd $ markError constraint $ unifyLTE unifier (Just syntheticLesser) whole
          (wholeLo, _) <- wholeComponents whole'
          let params' = fromJust $ Map.lookup inter wholeLo
          let paramUpdates = (zip paramVars params') :: [(var, Maybe (Type atom inter))]
          return $ (wholeVar, whole') : paramUpdates

  allConstraints <- foldM includeConstraint emptyConstraints (problemConstraints problem)

  let
    relationEnforcers =
      map (\(vars, rel) -> enforceRelation (items vars) rel) $
      Map.toList $ relationConstraints allConstraints

    formulationEnforcers = map enforceFormulation $ formulationConstraints allConstraints

    funcEnforcers = map enforceFuncConstraint $ funcConstraints allConstraints

    interactionEnforcers = map enforceInteractionConstraint $ interactionConstraints allConstraints

    differenceEnforcers = map enforceDifferenceConstraint $ interactionDifferenceConstraints allConstraints

    allEnforcers = concat
      [ relationEnforcers
      , formulationEnforcers
      , funcEnforcers
      , interactionEnforcers
      , differenceEnforcers
      -- don't forget to add new enforcer types here!
      ]

    propagationProblem = Prop.Problem
      { Prop.problemInitialVals = map (second Just) $ Map.toList $ boundConstraints allConstraints
      , Prop.problemDefaultVal = Nothing
      , Prop.problemConstraints = allEnforcers
      , Prop.problemMergeUpdates = mergeUpdates
      }

  solution <- Prop.solve propagationProblem
  return (join . solution)
