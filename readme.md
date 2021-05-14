[![Open in Gitpod](https://gitpod.io/button/open-in-gitpod.svg)](https://gitpod.io/#https://github.com/justinbarclay/copy-schema-demo)

> Buckle up, this could be a long drive

# Copy Schema Demo
Hello, welcome to the interactive portion of our exam. 

In a few short moments a new window, or tab, should open up shortly. If you have a pop-up blocker enabled the ball is in your court to figure out how to open it.

Now for some, all, of you this might be a new experience because this is [Doom Emacs](https://github.com/doomemacs/doomemacs) running in the browser. And because of that fact I have prepared a short cheat-sheet of some keychords that might be useful to use while reading/interacting with this demo

## Cheat-sheet
| Keychord  | Action                      |
|-----------|-----------------------------|
| C-c C-c   | Execute code block          |
| C-c C-v n | Go to next code block       |
| C-c C-v p | Go to previous code block   |
| Tab       | Fold current heading        |
| Shift-Tab | Fold or unfold all heading  |
| C-h m     | List all keyboard shortcuts |

I think the keychord `C-c C-c`, or execute code block, is the least intuitive keychord on this cheat-sheet. Using this command properly is dependent on the position of your cursor, in so far as pressing `C-c C-c` will only evaluate the source code when the cursor is inside of or at the end of a source code block.

```
Cursor can be anywhere between here
|
v
#+begin_src sql
  SELECT check_existence('public');
#+end_src
        ^
        |
        and here
```

_Note:_ since most of the code blocks already have a `#+RESULTS:` section associated with them, you will want to change the query written in the source block before exectuing the code. Otherwise, you might think nothing is happening.
## For those who like to explore or become desperately lost
If the woods are deep and dark you can try pressing `M-x` and typing what you want do. A lot of Emacs' functionality is reasonably named and you might be able to stumble upon what you want.

Additionally, Doom Emacs uses [which-key](https://github.com/justbur/emacs-which-key), so if you start entering some key combination and wait a second a cheat-sheet will pop up to guide you to the command you want.
# Thanks
- [@yyoncho](https://github.com/yyoncho/yyoncho) and the rest of the emacs lsp community for the [lsp-gitlab](https://github.com/emacs-lsp/lsp-gitpod) project, that I used as inspiration for how to set up this demo
- [Michael Hartl](https://www.michaelhartl.com/) and his [Ruby on Rails](https://github.com/emacs-lsp/lsp-gitpod) tutorial book, that sparked my interest in programming and later my career.
