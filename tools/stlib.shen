\\ Writes a binary with the kernel's precompiled standard library (make stlib).
\\ The arguments are that file and the binary's path. As the kernel's port
\\ notes ask, it comes after the kernel, and stlib.initialise after it, which
\\ installs its arities, macros, datatypes and types, and makes the names it
\\ exports system functions. It cannot be loaded sealed: it defines min twice.

(map (/. X (eval-kl X)) (read-file (hd (tl (value *argv*)))))
(stlib.initialise)
(shen-jit.save-executable (hd (tl (tl (value *argv*)))) [])
