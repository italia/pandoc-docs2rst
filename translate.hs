#!/usr/bin/env stack
-- stack --resolver lts-10.10 script --package turtle --package text --package filepath --package directory
{-# LANGUAGE OverloadedStrings #-}

import Turtle hiding (splitDirectories, replaceExtensions, stdout, stderr)
import Data.List (intersperse)
import Data.Text (pack, unpack)
import System.FilePath.Posix
import System.Directory (createDirectoryIfMissing, withCurrentDirectory, copyFile)

parser :: Parser (Text, Text)
parser = (,) <$> optText "to" 't' "destination format"
             <*> optText "input" 'i' "file to translate"

offset = "../../../"

filters = concat $ intersperse " " $ map addFilter files
  where files = [ "add-headers.hs"
                , "merge-code.hs"
                , "remove-divs.hs"
                , "remove-quotes.hs"
                , "flatten.hs"
                , "loosen-lists.hs"
                ]

addFilter f = "--filter " <> unpack offset <> "pandoc-filters/filters/" <> f

opts = pack $ " --wrap none --extract-media media " <> filters


-- | convert the input file to the output folder
--
-- >>> fileToFolder "somedir/otherdir/file.ext"
-- "output/otherdir/file"
fileToFolder i = joinPath ["output", firstParent i, takeBaseName i]
  where firstParent = head . drop 1 . reverse . splitDirectories

-- | move the input file to the destination folder
--
-- >>> inputName "somedir/otherdir/file.ext"
-- "input.ext"
inputName i = addExtension "input" (takeExtension i)

-- | move the input file to the destination folder
--
-- >>> inToCopy "somedir/otherdir/file.ext"
-- "output/otherdir/file/input.ext"
inToCopy i = joinPath [fileToFolder i, inputName i]

-- | convert the input file to the output file
--
-- >>> inToOut "newExt"
-- "document.newExt"
inToOut = addExtension "document"

version = "pandoc"
--version = offset <> "fork" -- in order to use a local fork

-- | translate applying most filters
makeDocument :: Text -> Text -> Text
makeDocument it ft = version <> " " <> (x inFile) <> " " <> opts <> " -o " <> (x outFile)
  where outFile = pack $ inToOut f
        inFile = pack $ inputName i
        i = unpack it
        f = unpack ft
        x f = "\"" <> f <> "\""

-- | translate again applying the `to-sphinx` filter
makeSphinx = version <> " document.rst -o index.rst " <> (pack $ addFilter "to-sphinx.hs")

main = do
  (f, i) <- options "translate DOCX file" parser
  createDirectoryIfMissing True (fileToFolder (unpack i))
  copyFile (unpack i) (inToCopy (unpack i))
  withCurrentDirectory (fileToFolder (unpack i)) (do
      shell (makeDocument i f) empty
      -- print (makeDocument i f) -- for troubleshooting
      shell makeSphinx empty
      shell "test -e media && cp -r media index" empty -- for Sphinx
    )



