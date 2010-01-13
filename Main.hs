{-# LANGUAGE Arrows #-}
module Main where

import FRP.Yampa
import FRP.Yampa.Vector3
import FRP.Yampa.Utilities
import Graphics.UI.GLUT hiding (Level,Vector3(..),normalize)
import qualified Graphics.UI.GLUT as G(Vector3(..))

import Data.IORef
import Control.Arrow
import Data.Maybe
import Data.List

import GLAdapter

-- | Event Definition:

data Input = Keyboard { key       :: Key,
                        keyState  :: KeyState,
                        modifiers :: Modifiers }
-- | Rendering Code:

data Point3D = P3D { x :: Integer, y :: Integer, z :: Integer }

p3DtoV3 ::  (RealFloat a) => Point3D -> Vector3 a
p3DtoV3 (P3D x y z) = vector3 (fromInteger x) (fromInteger y) (fromInteger z)

vectorApply f v = vector3 (f $ vector3X v) (f $ vector3Y v) (f $ vector3Z v)

data Level = Level { startingPoint :: Point3D, 
                     endPoint      :: Point3D,
                     obstacles     :: [Point3D] }

-- TODO: Memoize
size :: Level -> Integer
size = (+1) . maximum . map (\(P3D x y z) -> maximum [x,y,z]) . obstacles

data GameState = Game { level     :: Level,
                        rotX      :: Double, 
                        playerPos :: Vector3 Double }

type R = Double

-- TODO: List can't be empty!
testLevel = Level (P3D 0 0 1) (P3D 4 4 5) [P3D 0 0 0, P3D 0 5 1, P3D 5 4 1]
testLevel2 = Level (P3D 0 0 1) (P3D 0 4 1) [P3D 5 5 5]

levels = concat (repeat [testLevel, testLevel2])

-- | Helpful OpenGL constants for rotation
xAxis = G.Vector3 1 0 0 :: G.Vector3 R 
yAxis = G.Vector3 0 1 0 :: G.Vector3 R
zAxis = G.Vector3 0 0 1 :: G.Vector3 R 

initGL :: IO (Event Input)
initGL = do
    getArgsAndInitialize
    createWindow "AnaCube!"
    initialDisplayMode $= [ WithDepthBuffer ]
    depthFunc          $= Just Less
    clearColor         $= Color4 0 0 0 0
    light (Light 0)    $= Enabled
    lighting           $= Enabled 
    lightModelAmbient  $= Color4 0.5 0.5 0.5 1 
    diffuse (Light 0)  $= Color4 1 1 1 1
    blend              $= Enabled
    blendFunc          $= (SrcAlpha, OneMinusSrcAlpha) 
    colorMaterial      $= Just (FrontAndBack, AmbientAndDiffuse)
    reshapeCallback    $= Just resizeScene
    return NoEvent

renderGame :: GameState -> IO ()
renderGame (Game l rotX pPos) = do
    loadIdentity
    translate $ G.Vector3 (0 :: R) 0 (-2*(fromInteger $ size l))
    -- TODO: calculate rotation axis based on rotX/Y
    rotate (rotX * 10) xAxis
    color $ Color3 (1 :: R) 1 1
    position (Light 0) $= Vertex4 0 0 0 1  
    renderObject Wireframe (Cube $ fromInteger $ size l)
    renderPlayer pPos
    renderGoal (p3DtoV3 $ endPoint l)
    mapM_ (renderObstacle . p3DtoV3) $ obstacles l
    flush
    where size2 :: R
          size2 = (fromInteger $ size l)/2
          green  = Color4 0.8 1.0 0.7 0.9 :: Color4 R
          greenG = Color4 0.8 1.0 0.7 1.0 :: Color4 R
          red    = Color4 1.0 0.7 0.8 1.0 :: Color4 R 
          renderShapeAt s p = preservingMatrix $ do
            translate $ G.Vector3 (0.5 - size2 + vector3X p)
                                  (0.5 - size2 + vector3Y p)
                                  (0.5 - size2 + vector3Z p)
            renderObject Solid s
          renderObstacle = (color green >>) . (renderShapeAt $ Cube 1)
          renderPlayer   = (color red >>) . (renderShapeAt $ Sphere' 0.5 20 20)
          renderGoal     = 
            (color greenG >>) . (renderShapeAt $ Sphere' 0.5 20 20) 

keyDowns :: SF (Event Input) (Event Input)
keyDowns = arr $ filterE ((==Down) . keyState)

countHold :: SF (Event a) Integer
countHold = count >>> hold 0

game :: SF GameState (IO ())
game = arr $ (\gs -> do
        clear [ ColorBuffer, DepthBuffer ]
        renderGame gs
        flush)

data ParsedInput = 
    ParsedInput { ws :: Integer, as :: Integer, ss :: Integer, ds :: Integer,
                  upEvs    :: Event Input, downEvs :: Event Input, 
                  rightEvs :: Event Input, leftEvs :: Event Input }
                        
-- | Input
parseInput :: SF (Event Input) ParsedInput
parseInput = proc i -> do
    down     <- keyDowns                        -< i
    ws       <- countKey 'w'                    -< down
    as       <- countKey 'a'                    -< down
    ss       <- countKey 's'                    -< down
    ds       <- countKey 'd'                    -< down
    upEvs    <- filterKey (SpecialKey KeyUp)    -< down
    downEvs  <- filterKey (SpecialKey KeyDown)  -< down
    rightEvs <- filterKey (SpecialKey KeyRight) -< down
    leftEvs  <- filterKey (SpecialKey KeyLeft)  -< down
    returnA -< ParsedInput ws as ss ds upEvs downEvs rightEvs leftEvs
    where countKey c  = filterE ((==(Char c)) . key) ^>> countHold
          filterKey k = arr $ filterE ((==k) . key)

-- | Logic
data WinLose = Win | Lose deriving (Eq)

calculateState :: SF ParsedInput GameState
calculateState = proc pi@(ParsedInput ws as ss ds _ _ _ _) -> do
    rec speed    <- rSwitch selectSpeed -< ((pi, pos, speed, obstacles level),
                                            winLose `tag` selectSpeed)
        posi     <- drSwitch (integral) -< (speed, winLose `tag` integral)
        pos      <- arr calculatePPos -< (posi, level)
        winLose  <- arr testWinLoseCondition -< (pos, level)
        wins     <- arr (filterE (==Win)) >>> delayEvent 1 -< winLose 
        level    <- countHold >>^ fromInteger >>^ (levels !!) -< wins 
 
    -- TODO: watch for leak on ws/as/ss/ds
    returnA -< Game { level     = level,
                      rotX      = (fromInteger $ (ws - ss)),
                      playerPos = pos }

    where calculatePPos (pos, level) = pos ^+^ (p3DtoV3 $ startingPoint level)
          testBounds pos size = let sizeN = fromInteger size
                                in vector3X pos > sizeN || vector3X pos < 0 ||
                                   vector3Y pos > sizeN || vector3Y pos < 0 ||
                                   vector3Z pos > sizeN || vector3Z pos < 0 
          -- TODO: Abstract further?
          testWinLoseCondition (pos, level)
            | pos == (p3DtoV3 $ endPoint level) = Event Win
            | testBounds pos (size level)       = Event Lose
            | otherwise                         = NoEvent

selectSpeed :: SF (ParsedInput, Vector3 Double, Vector3 Double, [Point3D]) 
                  (Vector3 Double)
selectSpeed = proc (pi, pos, speed, obss) -> do
    let rotX = (fromInteger $ ((ws pi) - (ss pi)) `mod` 36 + 36) `mod` 36
        theta = (((rotX - 6) `div` 9) + 1) `mod` 4
    -- TODO: Get rid of the undefineds? 
    speedC <- drSwitch (constant zeroVector) -< 
        (undefined, tagKeys (upEvs pi) speed ((-v) *^ zAxis) theta `merge` 
                    tagKeys (downEvs pi) speed (v *^ zAxis) theta `merge`
                    tagKeys (leftEvs pi) speed ((-v) *^ xAxis) theta `merge`
                    tagKeys (rightEvs pi) speed (v *^ xAxis) theta) 
    cols   <- collision ^>> boolToEvent -< (obss, pos, speedC)
    speedf <- rSwitch (constant zeroVector) -< (speedC, tagCols cols) 
    returnA -< speedf
    
    where xAxis = vector3 1 0 0 
          yAxis = vector3 0 1 0
          zAxis = vector3 0 0 1
          v     = 0.5
          collision (obss,pos,speed) = 
              any (\obs -> norm (pos ^+^ (2 *^ speed) ^-^ (p3DtoV3 obs)) 
                            <= 0.001) obss
          -- TODO: Confusing names, can they be generalized?
          tagKeys event speed vector theta
              | speed == zeroVector = event `tag` constant 
                                        (vector3Rotate' theta vector)
              | otherwise           = NoEvent
          tagCols cols
              | isNoEvent cols  = Event identity
              | otherwise       = cols `tag` constant zeroVector
          boolToEvent = arr (\bool -> if bool then Event () else NoEvent)

vector3Rotate' :: (Integral a, RealFloat b) => a -> Vector3 b -> Vector3 b
vector3Rotate' theta v =
  let rotateTheta 0 v = id v                                
      rotateTheta 1 v = vector3 (vector3X v) (vector3Z v)    (-(vector3Y v))
      rotateTheta 2 v = vector3 (vector3X v) (-(vector3Y v)) (-(vector3Z v)) 
      rotateTheta 3 v = vector3 (vector3X v) (-(vector3Z v))   (vector3Y v)
      rotateTheta i _ = rotateTheta (abs $ i `mod` 4) v
  in rotateTheta theta $ v

-- | Main, initializes Yampa and sets up reactimation loop
main :: IO ()
main = do
    newInput <- newIORef NoEvent
    rh <- reactInit initGL (\_ _ b -> b >> return False) 
                    (parseInput >>> calculateState >>> game)
    displayCallback $= return ()
    keyboardMouseCallback $= Just 
        (\k ks m _ -> writeIORef newInput (Event $ Keyboard k ks m))
    idleCallback $= Just (idle newInput rh) 
    mainLoop

-- | Reactimation iteration, supplying the input
idle :: IORef (Event Input) -> ReactHandle (Event Input) (IO ()) -> IO ()
idle newInput rh = do
    newInput' <- readIORef newInput
    react rh (1, Just newInput')
    return ()
    
