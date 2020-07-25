{-# LANGUAGE CPP                 #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Math.NumberTheory.Primes.Factorisation.QuadraticSieve
  ( quadraticSieve
  ) where

#if __GLASGOW_HASKELL__ < 803
import Data.Semigroup
#endif
import qualified Data.List as L
import qualified Data.Vector as V
import qualified Data.Vector.Sized as SV
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Sized as SU
import qualified Data.Vector.Mutable as MV
import qualified Data.IntMap as I
import qualified Math.NumberTheory.Primes.IntSet as PS
import Control.Monad
import Control.Monad.ST
import Data.Maybe
import Data.Bit
import Data.Bifunctor
import Math.NumberTheory.Roots
import Math.NumberTheory.Primes
import Math.NumberTheory.Moduli.Sqrt
import Math.NumberTheory.Utils.FromIntegral
import Math.NumberTheory.Primes.Factorisation.LinearAlgebra
import GHC.TypeNats
import Data.Proxy
import Data.Kind

data SignedPrimeIntSet = SignedPrimeIntSet
  { sign :: !Bool
  , primeSet :: !PS.PrimeIntSet
  } deriving (Show)

insert :: Prime Int -> SignedPrimeIntSet -> SignedPrimeIntSet
insert prime (SignedPrimeIntSet s ps) = SignedPrimeIntSet s (prime `PS.insert` ps)

-- | Given an odd positive composite Integer @n@ and Int parameters @b@ and @t@,
-- the Quadratic Sieve attempts to output @factor@, a factor of @n@. If it fails,
-- it throws an exception. The parameter @b@ controls the size of the factor base.
-- This consists of all the relevant primes which are less than or equal to @b@.
-- The parameter @t@ controls the length of the sieving interval.
quadraticSieve :: Integer -> Int -> Int -> Integer
quadraticSieve n b t = runST $ do
  let
    factorBase = [nextPrime 2..precPrime b]
    squareRoot = integerSquareRoot n
    sievingFunction j = j * j - n
    startingPoint = squareRoot - intToInteger t `div` 2

    goSieving :: [(Integer, SignedPrimeIntSet)] ->Integer -> Int -> [(Integer, SignedPrimeIntSet)]
    goSieving previousFactorisations newStartingPoint counter = runST $ do
      let
        sievingInterval = generateInterval sievingFunction newStartingPoint t
      sievingIntervalM <- V.thaw sievingInterval
      smoothSieveM sievingIntervalM factorBase n newStartingPoint
      sievingIntervalF <- V.unsafeFreeze sievingIntervalM
      let
        smoothNumbers = previousFactorisations ++ V.toList (findSmoothNumbers newStartingPoint sievingIntervalF)
        suitableSmoothNumbers = removeRows smoothNumbers
        matrix
          -- Also takes the sign into account.
          | numberOfPrimes < length mat - 1 = suitableSmoothNumbers -- trace (show (numberOfPrimes, length mat, counter)) $ suitableSmoothNumbers
          | odd counter                     = goSieving smoothNumbers (newStartingPoint + intToInteger (counter * t)) (counter + 1)
          | otherwise                       = goSieving smoothNumbers (newStartingPoint - intToInteger (counter * t)) (counter + 1)
          where
            numberOfPrimes = PS.size (foldr (\col acc -> acc <> primeSet col) mempty mat)
            mat = fmap snd suitableSmoothNumbers
      pure matrix

    indexedSmoothNumbers = goSieving [] startingPoint 1

    goSolving :: [(Integer, SignedPrimeIntSet)] -> Integer
    goSolving sievingData
      | factor /= 1 && factor /= n                                          = factor
      | (firstSquare ^ (2 :: Int) - secondSquare ^ (2 :: Int)) `mod` n /= 0 = error "Algorithm incorrect."
      | otherwise                                                           = 1 -- goSolving sievingData
      where
        factor = gcd (firstSquare - secondSquare) n
        firstSquare = findFirstSquare n (V.fromList (fmap fst sievingData)) solution
        secondSquare = findSecondSquare n (V.fromList (fmap (snd . second primeSet) sievingData)) solution
        solution = convertToList $ linearSolve' $ translate $ fmap snd sievingData

  pure $ goSolving indexedSmoothNumbers

-- This routine generates the sieving interval. It takes a function @f@,
-- @startingPoint@, and a dimension @dim@. It returns tuples whose
-- first component is @f@ applied to @x@, as @x@ runs from @startingPoint@
-- for a toal length of @dim@. The second component stores the factorisation
-- modulo 2 as an SignedPrimeIntSet. It is initialised to store whether the
-- @x@ is positive and negative. Its factorisation is computed in the sieve.
generateInterval :: (Integer -> Integer) -> Integer -> Int -> V.Vector (Double, SignedPrimeIntSet)
generateInterval f startingPoint dim = V.generate dim go
  where
    go i = x `seq` sps `seq` (x, sps)
      where
        x = log . fromIntegral $ f (intToInteger i + startingPoint)
        sps = SignedPrimeIntSet (x < 0) mempty

-- This algorithm takes @sievingIntervalM@, @factorBase@, the integer @n@ to be
-- factored and the @startingPoint@. It divides by all the primes in
-- @factorBase@ storing the factorisations of the numbers in the
-- @sievingIntervalM@. When, a division occurs, the value in the interval is
-- divided. At the end of the process, the smooth numbers correspond to tuples
-- whose first component is 1. The second component is their factorisation.
smoothSieveM :: MV.MVector s (Double, SignedPrimeIntSet) -> [Prime Int] -> Integer -> Integer -> ST s ()
smoothSieveM sievingIntervalM factorBase n startingPoint = do
  let t = MV.length sievingIntervalM
  forM_ factorBase $ \prime -> do
    let modularSquareRoots = sqrtsModPrime n ((fromJust . toPrimeIntegral) prime)
    forM_ modularSquareRoots $ \modularSquareRoot -> do
      let startingIndex = integerToInt ((modularSquareRoot - startingPoint) `mod` (intToInteger . unPrime) prime)
      forM_ [startingIndex, startingIndex + unPrime prime..(t - 1)] $ \entry -> do
        let change (y, set) = (y - (log . fromIntegral . unPrime) prime, prime `insert` set)
        MV.modify sievingIntervalM change entry

-- This algorithm filters the @sievingIntervalF@ for smooth numbers. It returns
-- the smooth numbers together with their index. This is needed in order to
-- later retrieve the value of @x@ and therefore @f(x)@. This index is stored
-- as a singleton IntSet to prepare the data for Gaussian elimination.
findSmoothNumbers :: Integer -> V.Vector (Double, SignedPrimeIntSet) -> V.Vector (Integer, SignedPrimeIntSet)
findSmoothNumbers startingPoint = V.imapMaybe selectSmooth
  where
    selectSmooth index (logResidue, factorisation)
      -- 0.6 should be accurate enough as it is slightly less that log 2
      | logResidue < 0.6 = Just (intToInteger index + startingPoint, factorisation)
      | otherwise        = Nothing

-- Find all primes, which appear only once in the input list.
appearsOnlyOnce :: [PS.PrimeIntSet] -> PS.PrimeIntSet
appearsOnlyOnce = fst . L.foldl' go (mempty, mempty)
  where
    go (onlyOnce, atLeastOnce) x =
      ((onlyOnce PS.\\ PS.unPrimeIntSet x) <> (x PS.\\ PS.unPrimeIntSet atLeastOnce), atLeastOnce <> x)

-- Removes all columns of the matrix which contain primes appearing only once.
-- These columns cannot be part of the solution.
removeRows :: [(Integer, SignedPrimeIntSet)] -> [(Integer, SignedPrimeIntSet)]
removeRows indexedFactorisations
  | onlyOnce == mempty = indexedFactorisations
  | otherwise          = removeRows $ filter (\(_, SignedPrimeIntSet _ xs) -> PS.disjoint xs onlyOnce) indexedFactorisations
  where
    onlyOnce = appearsOnlyOnce $ map (primeSet . snd) indexedFactorisations

-- Given a solution, the value of @f(x)@ is computed again. By construction,
-- the solution IntSet consists of values which correspond to columns in the
-- original sieving interval.
findFirstSquare :: Integer -> V.Vector Integer -> [Int] -> Integer
findFirstSquare n values = foldr construct 1
  where
    construct solutionIndex previous = ((values V.! solutionIndex) * previous) `mod` n

-- Finds the factorisations corresponding to the selected solutions and computes
-- the total number of times a given prime occurs in the selected factorisations.
-- By construction, for any given prime, this number is even. From here, a
-- square root is computed.
findSecondSquare :: Integer -> V.Vector PS.PrimeIntSet -> [Int] -> Integer
findSecondSquare n factorisations solution = I.foldrWithKey computeRoot 1 countPowers
  where
    computeRoot key power previous = (intToInteger key ^ (if even power then (power `div` 2 :: Int) else error "Wrong second square") * previous) `mod` n
    countPowers = foldl count I.empty squares
    count = PS.foldr (\prime im -> I.insertWith (+) (unPrime prime) (1 :: Int) im)
    squares = map (factorisations V.!) solution

data SomeKnown (f :: Nat -> Type) where
  SomeKnown :: KnownNat k => f k -> SomeKnown f

convertToList :: SomeKnown DBVector -> [Int]
convertToList (SomeKnown solution) = listBits $ SU.fromSized $ unDBVector solution

translate :: [SignedPrimeIntSet] -> SomeKnown SBMatrix
translate listOfFactorisations = translateHelper listOfFactorisations (length listOfFactorisations)
  where
    translateHelper :: [SignedPrimeIntSet] -> Int -> SomeKnown SBMatrix
    translateHelper columns dim = case someNatVal (fromIntegral dim) of
      SomeNat (_ :: Proxy dim) -> let result :: SBMatrix dim = SBMatrix (fromJust (SV.fromList (map toIndices columns))) in
        SomeKnown result
          where
            toIndices :: KnownNat dim => SignedPrimeIntSet -> SBVector dim
            toIndices x = SBVector $ U.fromList $ map fromIntegral $ if sign x then 0 : primeTranslation else primeTranslation
                  where
                    primeTranslation :: [Int]
                    primeTranslation = binarySearch (PS.toAscList (primeSet x)) $ indexPrimes columns

linearSolve' :: SomeKnown SBMatrix -> SomeKnown DBVector
linearSolve' (SomeKnown m) = SomeKnown (linearSolve m)

indexPrimes :: [SignedPrimeIntSet] -> U.Vector (Prime Int)
indexPrimes list = U.fromList . PS.toAscList $ go list
  where
    go :: [SignedPrimeIntSet] -> PS.PrimeIntSet
    go = foldr ((<>) . primeSet) mempty

binarySearch :: (Eq a, Ord a, U.Unbox a) => [a] -> U.Vector a -> [Int]
binarySearch list v = go 0 (len - 1) list v
  where
    len = U.length v
    go :: (Eq a, Ord a, U.Unbox a) => Int -> Int -> [a] -> U.Vector a -> [Int]
    go _ _ [] _ = []
    go lowerIndex upperIndex allItems@(item : otherItems) vector = case item `compare` entry of
      LT -> go lowerIndex (currentIndex - 1) allItems vector
      -- @(currentIndex + 1)@ makes sure no prime number index is 0
      -- 0 is reserved for negative numbers
      EQ -> (currentIndex + 1) : go (currentIndex + 1) len otherItems vector
      GT -> go (currentIndex + 1) upperIndex allItems vector
      where
        entry = vector U.! currentIndex
        currentIndex = (upperIndex + lowerIndex) `div` 2
