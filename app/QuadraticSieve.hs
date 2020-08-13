import Math.NumberTheory.Primes.Factorisation.QuadraticSieve

main :: IO ()
main = print $ quadraticSieve n t (2 * t) 3
  where
    t = floor b
    b = (*15) . sqrt . exp . sqrt $ log (fromInteger n) * log (log (fromInteger n)) :: Double
    n = 313171213163547737474104867123
      -- 313171213163547737474104867123
      -- 820239374043355485537790987979115484333
      -- 1000000000100000000000000000074000000005700000000000000000969
