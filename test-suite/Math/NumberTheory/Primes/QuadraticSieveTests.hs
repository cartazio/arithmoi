module Math.NumberTheory.Primes.QuadraticSieveTests
  ( testSuite
  ) where

import Test.Tasty
import Test.Tasty.QuickCheck as QC
import Math.NumberTheory.TestUtils ()
import Math.NumberTheory.Primes
import Math.NumberTheory.Primes.Factorisation.QuadraticSieve
import qualified Debug.Trace

trace :: String -> a -> a
trace = if debug then Debug.Trace.trace else const id

debug :: Bool
debug = True

-- checkQuadratic :: Large Int -> Large Int -> Bool
-- checkQuadratic (Large i) (Large j)
--   -- Quadratic Sieve does not work in these cases.
--   | p == 2 || q == 2 || p == q = True
--   -- The value of @b@ is too low for sieving to be successful.
--   | n < 100000                 = True
--   | otherwise                  = (firstSquare ^ (2 :: Int) - secondSquare ^ (2 :: Int)) `mod` n == 0
--     where
--       (firstSquare, secondSquare) = trace ("Number: " ++ show n) $ head $ findSquares n t (2 * t) 1
--       t = floor l
--       l = (*25) . sqrt . exp . sqrt $ log (fromInteger n) * log (log (fromInteger n)) :: Double
--       n = toInteger p * toInteger q
--       p = unPrime . nextPrime $ i `mod` 100000000
--       q = unPrime . nextPrime $ j `mod` 100000000

checkQuadratic :: Large Int -> Large Int -> Bool
checkQuadratic (Large i) (Large j)
  | p == 2 || q == 2 || p == q = True
  | otherwise                  = n `mod` factor == 0
  where
    factor = trace ("Number: " ++ show n) $ quadraticSieve n
    n = p * q
    p = toInteger . unPrime . nextPrime $ i `mod` 100000000
    q = toInteger . unPrime . nextPrime $ j `mod` 100000000

testSuite :: TestTree
testSuite = testGroup "QuadraticSieve"
  [ QC.testProperty "Successful Factorisations" checkQuadratic
  ]
