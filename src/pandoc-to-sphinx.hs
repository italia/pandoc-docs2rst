{-# LANGUAGE OverloadedStrings #-}
module Main where

import Text.Pandoc
import Text.Pandoc.JSON
import Text.Pandoc.Options
import Text.Pandoc.Walk (query, walk)
import Text.Pandoc.Class (runIOorExplode)
import qualified Data.Text.IO as T
import Data.Text(Text(..))
import Data.Monoid ((<>))
import Options.Applicative
import Control.Monad (sequence_, join, void)
import Data.Either (fromRight)
import Data.List (intercalate)
import System.Directory (createDirectory,
                         removeDirectoryRecursive,
                         doesFileExist,
                         doesPathExist)
import Control.Applicative ((<$>))
import Control.Monad (when)
import System.FilePath.Posix (dropExtension, addExtension)
import Turtle (shell)
import System.Exit
import Data.Maybe (isNothing)

data Options = Version | Options {
  wrapNoneOption :: Bool,
  levelOption :: Maybe Int,
  secondLevelOption :: Maybe Int
  }

options :: Parser Options
options = flag' Version (long "version") <|>
          (Options <$> flag False True (long "wrap-none")
                   <*> optional (option auto (long "level"))
                   <*> optional (option auto (long "second-level")))

main = do
    opts <- execParser (info options fullDesc)
    case opts of
      Version -> do
        putStrLn "comandi conversione 0.5"
        exitSuccess
      (Options wrapNone maybeLevel1 maybeLevel2) -> do
        checkLevels maybeLevel1 maybeLevel2
        T.getContents >>= splitWrite wrapNone maybeLevel1 maybeLevel2 . parseDoc
        shell "test -e media && cp -r media index" empty
  where checkLevels (Just l1) (Just l2) =
          when (l1 >= l2) (die "the second level is not higher than the first")
        checkLevels _ _ = pure ()
        parseDoc = fromRight (Pandoc nullMeta []) . readJSON def

data ToWrite = ToWrite { fileNameToWrite :: String, blocksToWrite :: [Block] }

splitWrite :: Bool -> Maybe Int -> Maybe Int -> Pandoc -> IO [()]
splitWrite wrapNone l1 l2 (Pandoc meta blocks)= do
  (root:firstSplit) <- split False l1 (ToWrite "index.rst" blocks)
  writeRoot root
  if isNothing l2
    then (mapM (writeBlocks opts) firstSplit)
    else (do
         secondSplit <- mapM (split True l2) firstSplit
         mapM createEmpty (map (dropExtension . fileNameToWrite) firstSplit)
         mapM (writeBlocks opts) (join secondSplit))
  where writeRoot (ToWrite _ []) = pure ()
        writeRoot (ToWrite path blocks) = writeDoc opts path (Pandoc meta blocks)
        opts = if wrapNone then def { writerWrapText = WrapNone } else def


split :: Bool -> Maybe Int -> ToWrite -> IO [ToWrite]
split nested maybeLevel (ToWrite parent blocks) = do
  paths <- sequence (map (sectionPath prefix) sections)
  pure (ToWrite parent (makeToc paths intro):(zipWith ToWrite paths sections))
    where (intro, sections) = breakSections level blocks
          level = defaultMaybe (autoLevel blocks) maybeLevel
          makeToc :: [String] -> [Block] -> [Block]
          makeToc paths intro = intro <> [tocTree 3 paths]
          prefix = if nested then (dropExtension parent) <> "/" else ""
          sectionPath :: String -> [Block] -> IO String
          sectionPath p [] = pure (p <> "empty-section")
          sectionPath p s = availablePath $ (p <> getPath (head s))

createEmpty dir = do
  exists <- doesPathExist dir
  when exists (removeDirectoryRecursive dir)
  createDirectory dir

writeBlocks :: WriterOptions -> ToWrite -> IO ()
writeBlocks opts (ToWrite _ []) = pure ()
writeBlocks opts (ToWrite path blocks) = writeDoc opts path (Pandoc nullMeta blocks)

writeDoc :: WriterOptions -> FilePath -> Pandoc -> IO ()
writeDoc opts path doc = do
  text <- runIOorExplode $ writeRST opts doc
  T.writeFile path text

availablePath :: String -> IO String
availablePath path = do
  (available, c) <- untilM isAvailable increment (path, 1)
  pure $ render (available, c)
  where render (p, 1) = p
        render o = withNumber o
        withNumber (p, c) = addExtension (dropExtension p <> "-" <> show c) ".rst"
        isAvailable x = not <$> (doesFileExist $ render x)
        increment (p, c) = (p, c+1)

-- | like `until` but for monadic functions
-- >>> let p a = Just (a > 3)
-- >>> untilM p (+1) 0
-- Just 4
untilM :: Monad m => (a -> m Bool) -> (a -> a) -> a -> m a
untilM p f i = do
  r <- p i
  if r then pure i else untilM p f (f i)

-- everything before the first header is the intro
breakSections :: Int -> [Block] -> ([Block], [[Block]])
breakSections level blocks = breakIntro (isHeading level) blocks

headDefault :: a -> [a] -> a
headDefault d = defaultMaybe d . maybeHead

defaultMaybe :: a -> Maybe a -> a
defaultMaybe d Nothing = d
defaultMaybe _ (Just s) = s

maybeHead :: [a] -> Maybe a
maybeHead l
  | null l = Nothing
  | otherwise = Just (head l)

-- | if we have only one header 2 break by header 3 and so on
autoLevel :: [Block] -> Int
autoLevel body = headDefault 1 $ filter hasSeveral [1, 2, 3, 4, 5]
  where hasSeveral l = (length $ query (collectHeading l) body) > 1
        collectHeading l i = if isHeading l i then [i] else []

-- | see breakSections to get the purpose
-- >>> breakIntro (==' ') "bla bla bla b"
-- ("bla",[" bla"," bla"," b"])
-- >>> breakIntro (=='*') "bla bla bla b"
-- ("bla bla bla b",[])
breakIntro :: (a -> Bool) -> [a] -> ([a], [[a]])
breakIntro p l
  | p (head h) = ([], multiBroken)
  | otherwise  = (h, t)
  where multiBroken = multiBreak p l
        h = head multiBroken
        t = tail multiBroken

-- | Multiple version of break, like a `split` that keeps the delimiter
-- >>> multiBreak (==' ') "bla bla bla b"
-- ["bla"," bla"," bla"," b"]
multiBreak :: (a -> Bool) -> [a] -> [[a]]
multiBreak p [] = []
multiBreak p l@(h:t)
  | p h       = (h : t1) : multiBreak p t2
  | otherwise = l1 : multiBreak p l2
  where (t1, t2) = break p t
        (l1, l2) = break p l

{-

.. toctree::
   :maxdepth: 2
   :caption: Indice dei contenuti

   che-cos-e-docs-italia.rst
   starter-kit.rst

-}
tocTree :: Int -> [String] -> Block
tocTree _ [] = Null
tocTree depth paths = RawBlock "rst" $
           ".. toctree::" <>
           "\n  :maxdepth: " <> show depth <>
           "\n  :caption: Indice dei contenuti" <>
           "\n" <>
           concatMap (\x -> "\n  "<>x) paths

-- | get the path corresponding to some heading. use the identifier
-- if available, otherwise build a slug from the content
--
-- >>> getPath (Header 2 ("", [], []) [Str "section", Space, Str "accénted"])
-- "section-acc\233nted.rst"
getPath :: Block -> String
getPath (Header _ ("", _, _) i) = adapt (inlinesToText i) <> ".rst"
  where adapt = map replace . limit -- adapt for the file system
        limit = take 50 -- file names cannot be too long
        replace '/' = '-'
        replace o = o
getPath (Header _ (iden, _, _)  _) = iden <> ".rst"

isHeading :: Int -> Block -> Bool
isHeading a (Header b _ i) = a == b && (inlinesToText i /= "")
isHeading _ _ = False

-- | convert inlines to text. headers could contain any kind of
-- inlines, some of which cannot be converted to text for a file
-- name. we keep the text and drop the rest, removing also some inline
-- containers. other inline containers will be simply dropped.
--
-- >>> inlinesToText [Str "section", Space, Str "accénted"]
-- "section-acc\233nted"
-- >>> inlinesToText [Str "line", LineBreak, Str "break"]
-- "line-break"
-- >>> inlinesToText [Str "inline", Emph [Str "styled", Str "why?"]]
-- "inline-styled-why?"
-- >>> inlinesToText [Str "other", Note [], Str "inline"]
-- "other-inline"
inlinesToText :: [Inline] -> String
inlinesToText = intercalate "-" . concatMap inlineToText
  where inlineToText (Str s) = [s]
        inlineToText (Math _ s) = [s]
        inlineToText (Code _ s) = [s]
        inlineToText (Emph i) = c i
        inlineToText (Strong i) = c i
        inlineToText (Link _ i _) = c i
        inlineToText (Quoted _ i) = c i
        inlineToText (Cite _ i) = c i
        inlineToText (Image _ i _) = c i
        inlineToText (Span _ i) = c i
        inlineToText _ = []
        c = concatMap inlineToText
