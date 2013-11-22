{-# LANGUAGE Rank2Types #-}
-- | A histogram with an exponentially decaying reservoir produces quantiles which are representative of (roughly) the last five minutes of data.
-- It does so by using a forward-decaying priority reservoir with an exponential weighting towards newer data.
-- Unlike the uniform reservoir, an exponentially decaying reservoir represents recent data, allowing you to know very quickly if the distribution of the data has changed.
-- Timers use histograms with exponentially decaying reservoirs by default.
module Data.Metrics.Reservoir.ExponentiallyDecaying (
  ExponentiallyDecayingReservoir,
  standardReservoir,
  reservoir,
  clear,
  size,
  snapshot,
  rescale,
  update
) where
import Control.Monad.Primitive
import Control.Monad.ST
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Metrics.Internal
import qualified Data.Metrics.Reservoir as R
import qualified Data.Map.Strict as M
import Data.Metrics.Snapshot (Snapshot(..), takeSnapshot)
import Data.Primitive.MutVar
import qualified Data.Vector.Unboxed as V
import Data.Word
import System.Posix.Time
import System.Posix.Types
import System.Random.MWC

-- hours in seconds
rescaleThreshold :: Word64
rescaleThreshold = 60 * 60

-- | A forward-decaying priority reservoir
--
-- <http://dimacs.rutgers.edu/~graham/pubs/papers/fwddecay.pdf>
data ExponentiallyDecayingReservoir = ExponentiallyDecayingReservoir
  { _edrSize :: !Int
  , _edrAlpha :: !Double
  , _edrRescaleThreshold :: !Word64
  , _edrReservoir :: !(M.Map Double Double)
  , _edrCount :: !Int
  , _edrStartTime :: !Word64
  , _edrNextScaleTime :: !Word64
  , _edrSeed :: !Seed
  } deriving (Show)

-- | An exponentially decaying reservoir with an alpha value of 0.015 and a 1028 sample cap.
--
-- This offers a 99.9% confidence level with a 5% margin of error assuming a normal distribution,
-- and an alpha factor of 0.015, which heavily biases the reservoir to the past 5 minutes of measurements.
standardReservoir :: NominalDiffTime -> Seed -> R.Reservoir
standardReservoir = reservoir 0.015 1028

-- | Create a reservoir with a custom alpha factor and reservoir size.
reservoir :: Double -- ^ alpha value
  -> Int -- ^ max reservoir size
  -> NominalDiffTime -- ^ creation time for the reservoir
  -> Seed -> R.Reservoir
reservoir a r t s = R.Reservoir
  { R._reservoirClear = clear
  , R._reservoirSize = size
  , R._reservoirSnapshot = snapshot
  , R._reservoirUpdate = update
  , R._reservoirState = ExponentiallyDecayingReservoir r a rescaleThreshold M.empty 0 c c' s
  }
  where
    c = truncate t
    c' = c + rescaleThreshold

-- | Reset the reservoir
clear :: NominalDiffTime -> ExponentiallyDecayingReservoir -> ExponentiallyDecayingReservoir
clear = go
  where
    go t c = c { _edrStartTime = t', _edrNextScaleTime = t'', _edrCount = 0, _edrReservoir = M.empty }
      where
        t' = truncate t
        t'' = t' + _edrRescaleThreshold c

-- | Get the current size of the reservoir.
size :: ExponentiallyDecayingReservoir -> Int
size = go
  where
    go r = min c s
      where
        c = _edrCount r
        s = _edrSize r

-- | Get a snapshot of the current reservoir
snapshot :: ExponentiallyDecayingReservoir -> Snapshot
snapshot r = runST $ do
  let svals = V.fromList $ M.elems $ _edrReservoir $ r
  mvals <- V.unsafeThaw svals
  takeSnapshot mvals

weight :: Double -> Word64 -> Double
weight alpha t = exp (alpha * fromIntegral t)

-- | \"A common feature of the above techniques—indeed, the key technique that
-- allows us to track the decayed weights efficiently – is that they maintain
-- counts and other quantities based on g(ti − L), and only scale by g(t − L)
-- at query time. But while g(ti −L)/g(t−L) is guaranteed to lie between zero
-- and one, the intermediate values of g(ti − L) could become very large. For
-- polynomial functions, these values should not grow too large, and should be
-- effectively represented in practice by floating point values without loss of
-- precision. For exponential functions, these values could grow quite large as
-- new values of (ti − L) become large, and potentially exceed the capacity of
-- common floating point types. However, since the values stored by the
-- algorithms are linear combinations of g values (scaled sums), they can be
-- rescaled relative to a new landmark. That is, by the analysis of exponential
-- decay in Section III-A, the choice of L does not affect the final result. We
-- can therefore multiply each value based on L by a factor of exp(−α(L′ − L)),
-- and obtain the correct value as if we had instead computed relative to a new
-- landmark L′ (and then use this new L′ at query time). This can be done with
-- a linear pass over whatever data structure is being used.\"
rescale :: Word64 -> ExponentiallyDecayingReservoir -> ExponentiallyDecayingReservoir
rescale now c = c
  { _edrReservoir = adjustedReservoir
  , _edrStartTime = now
  , _edrCount = M.size adjustedReservoir
  , _edrNextScaleTime = st
  }
  where
    potentialScaleTime = now + rescaleThreshold
    currentScaleTime = _edrNextScaleTime c
    st = if potentialScaleTime > currentScaleTime then potentialScaleTime else currentScaleTime
    diff = now - _edrStartTime c
    adjustKey x = x * exp (-alpha * fromIntegral diff)
    adjustedReservoir = M.mapKeys adjustKey $ _edrReservoir c
    alpha = _edrAlpha c

-- | Insert a new sample into the reservoir. This may cause old sample values to be evicted
-- based upon the probabilistic weighting given to the key at insertion time.
update :: Double -- ^ new sample value
  -> NominalDiffTime -- ^ time of update
  -> ExponentiallyDecayingReservoir
  -> ExponentiallyDecayingReservoir
update v t c = rescaled
  { _edrSeed = s'
  , _edrCount = newCount
  , _edrReservoir = addValue r
  } 
  where
    rescaled = if seconds >= _edrNextScaleTime c
      then rescale seconds c
      else c
    seconds = truncate t
    priority = weight (_edrAlpha c) (seconds - _edrStartTime c) / priorityDenom
    addValue r = if newCount <= _edrSize c
      then M.insert priority v r
      else if firstKey < priority
        -- it should be safe to use head here since we are over our reservoir capacity at this point
        -- caveat: reservoir capped at 0 max size
        then M.delete firstKey $ M.insertWith const priority v r
        else r
    r = _edrReservoir c
    firstKey = head $ M.keys r
    newCount = 1 + _edrCount c
    (priorityDenom, s') = runST $ do
      g <- restore $ _edrSeed c
      p <- uniform g
      s' <- save g
      return (p :: Double, s')

