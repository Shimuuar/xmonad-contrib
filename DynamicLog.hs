-----------------------------------------------------------------------------
-- |
-- Module      :  XMonadContrib.DynamicLog
-- Copyright   :  (c) Don Stewart <dons@cse.unsw.edu.au>
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  Don Stewart <dons@cse.unsw.edu.au>
-- Stability   :  unstable
-- Portability :  unportable
--
-- DynamicLog
--
-- Log events in:
--
-- >     1 2 [3] 4 8
--
-- format. Suitable to pipe into dzen.
--
-----------------------------------------------------------------------------

module XMonadContrib.DynamicLog (
    -- * Usage
    -- $usage 
    dynamicLog,
    dynamicLogWithTitle,
    dynamicLogWithTitleColored,
    dynamicLogXinerama,

    pprWindowSet,
    pprWindowSetXinerama
  ) where

-- 
-- Useful imports
--
import XMonad
import {-# SOURCE #-} Config (workspaces)
import Operations () -- for ReadableSomeLayout instance
import Data.Maybe ( isJust )
import Data.List
import Data.Ord ( comparing )
import qualified StackSet as S
import Data.Monoid
import XMonadContrib.NamedWindows
import Data.Char

-- $usage 
--
-- To use, set:
--
-- >    import XMonadContrib.DynamicLog
-- >    logHook = dynamicLog
--
-- To get the title of the currently focused window after the workspace list:
--
-- >    import XMonadContrib.DynamicLog
-- >    logHook = dynamicLogWithTitle
--
-- To have the window title highlighted in any color recognized by dzen:
--
-- >    import XMonadContrib.DynamicLog
-- >    logHook = dynamicLogWithTitleColored "white"
--

-- %import XMonadContrib.DynamicLog
-- %def -- comment out default logHook definition above if you uncomment any of these:
-- %def logHook = dynamicLog
-- %def logHook = dynamicLogWithTitle
-- %def logHook = dynamicLogWithTitleColored "white"


-- |
-- Perform an arbitrary action on each state change.
-- Examples include:
--      * do nothing
--      * log the state to stdout
--
-- | 
-- An example log hook, print a status bar output to dzen, in the form:
--
-- > 1 2 [3] 4 7 : full
--
-- That is, the currently populated workspaces, and the current
-- workspace layout
--  
dynamicLog :: X ()
dynamicLog = withWindowSet $ \ws -> do
    let ld = description . S.layout . S.workspace . S.current $ ws
        wn = pprWindowSet ws
    io . putStrLn $ concat [wn ," : " ,map toLower ld]

-- | Appends title of currently focused window to log output, and the
-- current layout mode, to the normal dynamic log format.
-- Arguments are: pre-title text and post-title text
--
-- The result is rendered in the form:
--
-- > 1 2 [3] 4 7 : full : urxvt
--
dynamicLogWithTitle_ :: String -> String -> X ()
dynamicLogWithTitle_ pre post= do
    -- layout description
    ld <- withWindowSet $ return . description . S.layout . S.workspace . S.current
    -- workspace list
    ws <- withWindowSet $ return . pprWindowSet
    -- window title
    wt <- withWindowSet $ maybe (return "") (fmap show . getName) . S.peek

    io . putStrLn $ concat [ws ," : " ,map toLower ld
                           , case wt of
                                   [] -> []
                                   s  -> " : " ++ pre ++ s ++ post
                           ]

dynamicLogWithTitle :: X ()
dynamicLogWithTitle = dynamicLogWithTitle_ "" ""

-- | 
-- As for dynamicLogWithTitle but with colored window title (for dzen use)
--
dynamicLogWithTitleColored :: String -> X ()
dynamicLogWithTitleColored color = dynamicLogWithTitle_ ("^fg(" ++ color ++ ")") "^fg()"

pprWindowSet :: WindowSet -> String
pprWindowSet s =  concatMap fmt $ sortBy cmp
            (map S.workspace (S.current s : S.visible s) ++ S.hidden s)
   where f Nothing Nothing   = EQ
         f (Just _) Nothing  = LT
         f Nothing (Just _)  = GT
         f (Just x) (Just y) = compare x y

         wsIndex = flip elemIndex workspaces . S.tag

         cmp a b = f (wsIndex a) (wsIndex b) `mappend` compare (S.tag a) (S.tag b)

         this     = S.tag (S.workspace (S.current s))
         visibles = map (S.tag . S.workspace) (S.visible s)

         fmt w | S.tag w == this         = "[" ++ S.tag w ++ "]"
               | S.tag w `elem` visibles = "<" ++ S.tag w ++ ">"
               | isJust (S.stack w)      = " " ++ S.tag w ++ " "
               | otherwise               = ""

-- |
-- Workspace logger with a format designed for Xinerama:
--
-- > [1 9 3] 2 7
--
-- where 1, 9, and 3 are the workspaces on screens 1, 2 and 3, respectively,
-- and 2 and 7 are non-visible, non-empty workspaces
--
dynamicLogXinerama :: X ()
dynamicLogXinerama = withWindowSet $ io . putStrLn . pprWindowSetXinerama

pprWindowSetXinerama :: WindowSet -> String
pprWindowSetXinerama ws = "[" ++ unwords onscreen ++ "] " ++ unwords offscreen
  where onscreen  = map (S.tag . S.workspace)
                        . sortBy (comparing S.screen) $ S.current ws : S.visible ws
        offscreen = map S.tag . filter (isJust . S.stack)
                        . sortBy (comparing S.tag) $ S.hidden ws
