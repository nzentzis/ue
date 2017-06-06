module Math.Rewrite (reductions, simplify) where

import Data.List
import Data.Maybe
import Data.Function
import Data.Expression
import Data.Units

import Math.Approximate
import Math.Rewrite.Engine

import Control.Monad
import Control.Applicative

rewriteRules :: [RewriteRule]
rewriteRules =
    let (a:b:c:d:e:f:[]) = map (RRIdentifier Any) "abcdef"
        (x:y:z:[]) = map (RRIdentifier Nonliteral) "xyz"
        (m:n:k:[]) = map (RRIdentifier Literal) "mnk" in [
    -- reordering terms to normal form
    (a =* n, n =* a),

    -- simple properties
    (a =- a, csti 0), (a =- csti 0, a), (csti 0 =- a, neg a),
    (neg a =+ a, csti 0), (a =+ (neg a), csti 0),
    (a =+ csti 0, a), (csti 0 =+ a, a),
    (a =* csti 0, csti 0), (csti 0 =* a, csti 0),
    (a =* csti 1, a), (csti 1 =* a, a),
    (a =/ a, csti 1),

    -- unary operations
    (neg $ neg a, a),

    -- addition/subtraction
    (a =+ neg a, csti 0), (a =- neg a, a =+ a),
    (a =+ (b =+ neg a), b), (a =+ (neg a =+ b), b),
    (a =+ (b =+ a), b =+ a =* csti 2), (a =+ (a =+ b), b =+ a =* csti 2),
    ((b =+ a) =+ a, b =+ a =* csti 2), ((a =+ b) =+ a, b =+ a =* csti 2),
    ((a =+ b) =- a, b), ((b =+ a) =- a, b), ((b =- a) =+ a, b),

    -- multiplication/division
    (a =* (b =/ a), b), ((b =/ a) =* a, b), ((a =* b) =/ a, b), ((b =* a) =/ a, b),
    ((n =* a) =/ m, (n =/ m) =* a), ((a =* n) =/ m, (n =/ m) =* a),
    (a =+ a, csti 2 =* a),
    (a =+ b=*a, (b =+ csti 1) =* a), (a =+ a=*b, (b =+ csti 1) =* a),
    (a =- b=*a, (b =- csti 1) =* a), (a =- a=*b, (b =- csti 1) =* a),
    ((neg a) =+ b=*a, (b =- csti 1) =* a), ((neg a) =+ a=*b, (b =- csti 1) =* a),
    -- factoring out coefficients
    (a=*b =+ a=*c, a =* (b =+ c)), (b=*a =+ c=*a, a =* (b =+ c)),
    (a =- (b =+ c), a =+ (neg b =+ neg c)), -- distribute subtraction
    (a =- (b =- c), a =+ (neg b =+ c)), -- distribute subtraction
    ((a =+ b=*c) =+ d=*c, (a =+ c=*(b =+ d))),
    ((a =+ b=*c) =- d=*c, (a =+ c=*(b =- d))),

    -- division
    (a=/b =+ c=/b, (a =+ c) =/ b),

    -- exponentiation
    (a =^ csti 0, csti 1), (a =^ csti 1, a), (a =^ csti (-1), (csti 1) =/ a),
    (csti 1 =^ a, a), (csti 0 =^ a, csti 0),
    (a =* a, a =^ csti 2),
    (a =* a=^b, a =^ (b =+ csti 1)), (a=^b =* a, a =^ (b =+ csti 1)),
    (a=^b =/ a, a =^ (b =- csti 1)), (a=^b =/ a=^c, a =^ (b =- c)),
    (a=^b =* a=^c, a =^ (b =+ c)),
    ((d =* a=^b) =* a=^c, d =* (a =^ (b =+ c))),
    ((a=^b =* d) =* a=^c, d =* (a =^ (b =+ c))),
    ((a =^ b) =* (d =* (a =^ c)), d =* (a =^ (b =+ c))),
    ((a =^ b) =* ((a =^ c) =* d), d =* (a =^ (b =+ c))),

    ((a =^ b) =^ c, a =^ (b =* c)),
    ((a =* b) =^ m, (a =^ m) =* (b =^ m)),
    ((m =^ a) =* (n =^ a), (m =* n) =^ a),

    -- basic equality simplifications
    -- only do this for nonliterals for now, until we can produce boolean values
    (x =: x, csti 1 =: csti 1),
    (n =: x, x =: n), -- constants always on right side of equality
    (a =* b =: a =* c, b =: c), (b =* a =: a =* c, b =: c),
    (a =* b =: c =* a, b =: c), (b =* a =: c =* a, b =: c),
    (a =* b =: a, b =: csti 1), (b =* a =: a, b =: csti 1),
    (a =+ b =: c =+ b, a =: c), (b =+ a =: c =+ b, a =: c), -- subtract both sides
    (a =+ b =: b =+ c, a =: c), (b =+ a =: b =+ c, a =: c), -- subtract both sides
    (a =+ b =: m =* b, a =: b =* (m =- csti 1)),  -- subtract from multiplication
    (a =+ b =: m =* a, b =: a =* (m =- csti 1)),

    -- solve simple algebra
    (n =* a =: m, a =: m =/ n), (n =/ a =: m, a =: m =* n),
    (n =+ a =: m, a =: m =- n), (a =- n =: m, a =: m =+ n)
    ]
    where
        cst :: Value -> RRExpr
        cst = RRExpr . Constant

        csti n = cst (IntValue n noUnit)

-- Utility function - take a function and produce a result only if it changes
-- the input.
onChange :: Eq a => (a -> a) -> a -> Maybe a
onChange f x = let v = f x in if x == v then Nothing else Just v

-- Extract lists of terms connected by addition and subtraction, converting the
-- subtracted terms to their negated forms.
collapseSum :: Expr -> [Expr]
collapseSum (BinaryExpr Add a b) = (collapseSum a) ++ (collapseSum b)
collapseSum (BinaryExpr Subtract a b) = (UnaryExpr Negate b) : (collapseSum a)
collapseSum e = [e]

-- Extract lists of terms connected by multiplication
collapseProd :: Expr -> [Expr]
collapseProd (BinaryExpr Multiply a b) = (collapseProd a) ++ (collapseProd b)
collapseProd e = [e]

-- Expand a list of summation terms into a tree of add/subtract operations
expandSum :: [Expr] -> Expr
expandSum = foldl1' join
    where
        join l (UnaryExpr Negate r) = BinaryExpr Subtract l r
        join l r = BinaryExpr Add l r

-- Expand a list of product terms into a tree of multiply operations
expandProd :: [Expr] -> Expr
expandProd = foldl1' (BinaryExpr Multiply)

-- Reorder a list of elements so equal terms are adjacent, and return the
-- groups. If all equal terms are already adjacent, don't change the input.
equalGroup :: Eq a => [a] -> [[a]]
equalGroup xs = fst $ fromJust $ find (null . snd) $
    iterate gatherMore ([], xs) where
    gatherMore (gs,(x:xs)) = let (g,ys) = partition (== x) xs in (gs ++ [x:g], ys)

-- just a local instance to make dimensions sortable for grouping
-- doesn't really implement anything specifically
instance Ord Dimension where
    compare Dimensionless Dimensionless = EQ
    compare (Dimension xs ys) (Dimension xs' ys') = foldl' mappend EQ
        [compare xs xs',
         compare ys ys']
    compare Dimensionless (Dimension _ _) = LT
    compare (Dimension _ _) Dimensionless = GT

-- Reorder a list of expressions to group similar ones
sortExprGroups :: [[Expr]] -> [[Expr]]
sortExprGroups = sortBy (\(a:_) (b:_)->mconcat $ map (\f->f a b)
            [depth, naming, dimensions, constSize]) where
        depth :: Expr -> Expr -> Ordering
        depth = compare `on` treeDepth

        naming :: Expr -> Expr -> Ordering
        naming (NameRef a) (NameRef b) = compare a b
        naming a@(NameRef _) (BinaryExpr _ l r) =
            (naming a l) `mappend` (naming a r)
        naming a@(NameRef _) (Constant _) = GT
        naming (UnaryExpr _ a) b = naming a b
        naming a (UnaryExpr _ b) = naming a b
        naming (BinaryExpr _ l r) b@(NameRef _) =
            (naming l b) `mappend` (naming r b)
        naming (Constant _) b@(NameRef _) = LT
        naming _ _ = EQ

        constSize :: Expr -> Expr -> Ordering
        constSize (Constant a) (Constant b) = compareValues a b
        constSize (UnaryExpr _ a) b = constSize a b
        constSize a (UnaryExpr _ b) = constSize a b
        constSize _ _ = EQ

        dimensions :: Expr -> Expr -> Ordering
        dimensions (Constant u) (Constant v) = compare (dimension u) (dimension v)
        dimensions (UnaryExpr _ a) v = dimensions a v
        dimensions u (UnaryExpr _ a) = dimensions u a
        dimensions (BinaryExpr _ a b) v =
            (dimensions a v) `mappend` (dimensions b v)
        dimensions u (BinaryExpr _ a b) =
            (dimensions u a) `mappend` (dimensions u b)
        dimensions _ _ = EQ

-- Reorder chains of commutative operations so like terms are adjacent.
reorderLikeTerms :: Expr -> Expr
reorderLikeTerms e@(BinaryExpr Subtract a b) = expandSum $ map expandSum $ sortExprGroups $ equalGroup $ collapseSum e
reorderLikeTerms e@(BinaryExpr Add a b) = expandSum $ map expandSum $ sortExprGroups $ equalGroup $ collapseSum e
reorderLikeTerms e@(BinaryExpr Multiply a b) = expandProd $ map expandProd $ sortExprGroups $ equalGroup $ collapseProd e
reorderLikeTerms e = e

maybeEither :: Either a b -> Maybe b
maybeEither (Left _) = Nothing
maybeEither (Right r) = Just r

-- Simplify integer arithmetic expressions
simplifyArithmetic :: Reduction
simplifyArithmetic e@(BinaryExpr Add (Constant _) (Constant _)) =
    maybeEither $ approx e
simplifyArithmetic e@(BinaryExpr Subtract (Constant _) (Constant _)) =
    maybeEither $ approx e
simplifyArithmetic e@(BinaryExpr Multiply (Constant _) (Constant _)) =
    maybeEither $ approx e
simplifyArithmetic (BinaryExpr Power -- whether to simplify constant chosen by heuristic
    (Constant (IntValue a u))
    (Constant (IntValue b v))) = if (isCompat v noUnit && a^b < 1000) then
        Just $ Constant $ IntValue (a^b) u else Nothing
simplifyArithmetic (BinaryExpr Divide
    (Constant (IntValue a u))
    (Constant (IntValue b v))) = if (a `mod` b) == 0 then
        (Just $ Constant $ IntValue (a `div` b) (u >/ v)) else Nothing
simplifyArithmetic e@(UnaryExpr Negate (Constant _)) = maybeEither $ approx e
simplifyArithmetic _ = Nothing

-- Utility function for expression binding. Applies the function to the first
-- list item for which it returns Just, then substitutes that into the rest of
-- the list.
applyOnce :: (a -> Maybe a) -> [a] -> Maybe [a]
applyOnce f [] = Nothing
applyOnce f (x:xs) = (fmap (:xs) $ f x) <|> (fmap (x:) $ applyOnce f xs)

-- Perform reduction on a subexpression, if possible. Return the original expr
-- with the altered subexpr substituted in.
reduceSubexpr :: Reduction
reduceSubexpr (BinaryExpr o l r) =
    (fmap (\x->BinaryExpr o x r) $ reduceExpr l) <|>
    (fmap (\x->BinaryExpr o l x) $ reduceExpr r)
reduceSubexpr (UnaryExpr o e) = (UnaryExpr o) <$> reduceExpr e
reduceSubexpr (FuncCall n args) = (FuncCall n) <$> applyOnce reduceExpr args
reduceSubexpr (RelationExpr o l r) =
    (fmap (\x->RelationExpr o x r) $ reduceExpr l) <|>
    (fmap (\x->RelationExpr o l x) $ reduceExpr r)
reduceSubexpr _ = Nothing

-- Perform one reduction on an expression
reduceExpr :: Expr -> Maybe Expr
reduceExpr e = foldl1' (<|>) $ map (\f->f e) [
    simplifyArithmetic,        -- eagerly simplify integer arithmetic
    onChange reorderLikeTerms, -- then group terms
    rewrite rewriteRules,      -- try to perform complex rewrite operations
    reduceSubexpr]             -- or try to reduce a subexpression

-- Build a potentially-infinite chain of successive reductions for an expression
reductions :: Expr -> [Expr]
reductions = unfoldr (\x->fmap (\e->(e,e)) $ reduceExpr x)

simplify :: Expr -> Expr
simplify e = if null (reductions e) then e else (last $ reductions e)
