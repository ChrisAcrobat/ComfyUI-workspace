#!/bin/bash
if test -d .git; then
  mv .git .git-
  cd ComfyUI/
  mv .git- .git
else
  mv .git- .git
  cd ComfyUI/
  mv .git .git-
fi
