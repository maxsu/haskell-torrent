-- | Rate calculation.
module RateCalc (
    -- * Types
      Rate
    -- * Interface
    , new
    , update
    , extractCount
    , extractRate
    )

where

import Data.Time.Clock

-- | A Rate is a record of information used for calculating the rate
data Rate = Rate
    { rate :: Double -- ^ The current rate
    , bytes :: Integer -- ^ The amount of bytes transferred since last rate extraction
    , count :: Integer -- ^ The amount of bytes transferred since last count extraction
    , nextExpected :: UTCTime -- ^ When is the next rate update expected
    , lastExt :: UTCTime          -- ^ When was the last rate update
    , rateSince :: UTCTime     -- ^ From where is the rate measured
    }

fudge :: NominalDiffTime
fudge = fromInteger 5 -- Seconds

maxRatePeriod :: NominalDiffTime
maxRatePeriod = fromInteger 20 -- Seconds

new :: UTCTime -> Rate
new t = Rate { rate = 0.0
             , bytes = 0
             , count = 0
             , nextExpected = addUTCTime fudge t
             , lastExt      = addUTCTime (-fudge) t
             , rateSince    = addUTCTime (-fudge) t
             }

-- | The call @update n rt@ updates the rate structure @rt@ with @n@ new bytes
update :: Integer -> Rate -> Rate
update n rt = rt { bytes = bytes rt + n
                 , count = count rt + n}

-- | The call @extractRate t rt@ extracts the current rate from the rate structure and updates the rate
--   structures internal book-keeping
extractRate :: UTCTime -> Rate -> (Double, Rate)
extractRate t rt =
  let oldWindow :: Double
      oldWindow = realToFrac $ diffUTCTime (lastExt rt) (rateSince rt)
      newWindow :: Double
      newWindow = realToFrac $ diffUTCTime t (rateSince rt)
      n         = bytes rt
      r = (rate rt * oldWindow + (fromIntegral n)) / newWindow
      expectN  = min 5 (round $ (fromIntegral n / (max r 0.0001)))
  in
     -- Update the rate and book-keep the missing pieces. The total is simply a built-in
     -- counter. The point where we expect the next update is pushed at most 5 seconds ahead
     -- in time. But it might come earlier if the rate is high.
     -- Last is updated with the current time. Finally, we move the windows earliest value
     -- forward if it is more than 20 seconds from now.
        (r, rt { rate = r
               , bytes = 0
               , nextExpected = addUTCTime (fromInteger expectN) t
               , lastExt = t
               , rateSince = max (rateSince rt) (addUTCTime (-maxRatePeriod) t)
               })

-- | The call @extractCount rt@ extract the bytes transferred since last extraction
extractCount :: Rate -> (Integer, Rate)
extractCount rt = (count rt, rt { count = 0 })

