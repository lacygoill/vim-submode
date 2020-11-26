if exists('g:autoloaded_submode')
    finish
endif
let g:autoloaded_submode = 1

" Init {{{1

" A string to hide internal key mappings from the `'showcmd'` area.
" https://github.com/kana/vim-submode/issues/3
"
" We use no-break spaces (`U+00A0`), because:
"
"    - in the showcmd area, a normal space (U+0020) is rendered as "<20>" since Vim 7.4.116
"    - in insert mode, in the cell right after the cursor, a normal spaced is rendered as " "
"    - `U+00A0` is rendered as an invisible glyph if `'encoding'` is set to one of Unicode encodings
"
" `U+00A0` is really rendered as an *invisible* glyph; not " ".
" If it was rendered as " ", when  you're in a submode entered from insert mode,
" the character after the cursor would be hidden until the timeout.
" That's not the case; it always remains visible.

" Why `5`?{{{
"
" It seems the command-line only displays the last 10 bytes of the typeahead buffer.
" And a no-break space takes 2 bytes, so we need 5 of them to occupy the 10 bytes.
"}}}
const s:STEALTH_TYPEAHEAD = repeat('<char-0xa0>', 5)
"                                   ├─────────┘
"                                   └ `:h <Char>`

const s:FLAG2ARG = {
    \ 'b': '<buffer>',
    \ 'e': '<expr>',
    \ 'n': '<nowait>',
    \ 's': '<silent>',
    \ 'S': '<script>',
    \ }

" Interface {{{1
fu submode#enter(name, modes, flags, lhs, rhs) abort "{{{2
    " What the function does can be boiled down to this:{{{
    "
    "     imap <c-g>j <c-x><c-e><plug>(prefix)
    "     imap <plug>(prefix)j <c-g>j
    "     ino <plug>(prefix) <nop>
    "
    "     imap <c-g>k <c-x><c-y><plug>(prefix)
    "     imap <plug>(prefix)k <c-g>k
    "
    " In this example, we  want `C-g j` to enter a submode  from insert mode, in
    " which we can simply press `j` to scroll the window one line up.
    "
    " Note that this works in a simple  test, but it's brittle because some keys
    " can be  wrongly remapped.  Our  current implementation uses  more `<plug>`
    " mappings to be more robust.
    "
    " For some more details, see:
    " https://vi.stackexchange.com/a/24403/17449
    "}}}
    " Here is an example of invocations for this function:{{{
    "
    "     call submode#enter('scrollwin', 'i', '', '<c-g>j', '<c-x><c-e>' )
    "     call submode#enter('scrollwin', 'i', '', '<c-g>k', '<c-x><c-y>' )
    "                         │            │   │    │         │
    "                         │            │   │    │         └ rhs: how the keys must be expanded
    "                         │            │   │    └ lhs: the keys to press to enter 'scrollwin'
    "                         │            │   └ flags: no flag
    "                         │            └ mode: 'scrollwin' can be entered from insert mode
    "                         └ name: the submode is named 'scrollwin'
    "}}}
    " And here are the resulting *recursive* mappings:{{{
    "
    "     <c-g>j  <plug>(sm-exe:scrollwin:<c-g>j)<plug>(sm-show:scrollwin)<plug>(sm-prefix:scrollwin)_____
    "     <c-g>k  <plug>(sm-exe:scrollwin:<c-g>k)<plug>(sm-show:scrollwin)<plug>(sm-prefix:scrollwin)_____
    "             ├─────────────────────────────┘├───────────────────────┘├──────────────...
    "             │                              │                        └ type an ad-hoc prefix
    "             │                              │ so that you can repeat commands with 1 keypress
    "             │                              │ (here 'j' and 'k' can repeat '<c-g>j' and '<c-g>k')
    "             │                              │
    "             │                              └ show you the name of the submode you're in (here 'scrollwin')
    "             │
    "             └ execute the desired command (here C-x C-y)
    "
    "     <plug>(sm-prefix:scrollwin)_____j  <c-g>j
    "     <plug>(sm-prefix:scrollwin)_____k  <c-g>k
    "     ├──────────────────────────────┘│  ├────┘
    "     │                               │  └ repeat the whole process:
    "     │                               │
    "     │                               │      - execute desired command
    "     │                               │      - show name of the submode
    "     │                               │      - feed the ad-hoc prefix automatically
    "     │                               │
    "     │                               └ *this* is meant to be typed interactively
    "     │
    "     └ you'll never type this ad-hoc prefix interactively,
    "       it will always be fed to the typeahead automatically from a previous mapping expansion,
    "       but it will never be executed immediately because there will always be an ambiguity
    "       (another mapping is going to be installed with this prefix as its entire lhs)
    "
    " Note  that  in reality,  the  sequences  of  underscores are  replaced  by
    " sequences of no-break  spaces to be invisible on the  command-line (and on
    " the cursor cell in insert mode).
    "}}}
    "   As well as the *non*-recursive mappings:{{{
    "
    "     <plug>(sm-exe:scrollwin:<c-g>j)  <c-x><c-e>
    "     <plug>(sm-exe:scrollwin:<c-g>k)  <c-x><c-y>
    "
    "     <plug>(sm-show:scrollwin) <cmd>call <SNR>123_show_submode('scrollwin')<cr>
    "
    "     <plug>(sm-prefix:scrollwin)_____  <cmd>call <SNR>123_on_leaving_submode()<cr>
    "}}}
    for mode in split(a:modes, '\zs')
        call s:install_mappings(a:name, mode, a:flags, a:lhs, a:rhs)
    endfor
endfu
"}}}1
" Core {{{1
fu s:install_mappings(name, mode, flags, lhs, rhs) abort "{{{2
    " Why do you include `a:name` after the plug key?{{{
    "
    " The sequence of characters following the plug key must be unique enough.
    " For example, you could use the  same key (e.g. `C-g j`) to enter different
    " submodes from different modes (e.g.  insert and normal modes), and execute
    " different  commands.  You  can't use  the  same lhs  to execute  different
    " commands.
    "
    " You could use `a:mode` instead of `a:name`,  but if you have an issue with
    " a submode,  it's easier to  find all the  relevant mappings when  they all
    " share a telling name:
    "
    "     <Plug>(sm-exe:scrollwin:<C-G>j) * <C-X><C-E>
    "                   ^-------^
    "                   easy to find
    "
    "     <Plug>(sm-exe:i:<C-G>j) * <C-X><C-E>
    "                   ^
    "                   hard to find
    "}}}
    let plug_exe = printf('<plug>(sm-exe:%s:%s)', a:name, a:lhs)
    let plug_prefix = printf('<plug>(sm-prefix:%s)%s', a:name, s:STEALTH_TYPEAHEAD)
    let plug_show = printf('<plug>(sm-show:%s)', a:name)

    " Install mapping on `a:lhs` to make it enter a submode.
    " The mapping must be recursive, because its rhs contains `<plug>` keys.
    " Why bother with `plug_exe`?  Why not just use `a:rhs` directly?{{{
    "
    " Suppose that `a:rhs` is a built-in command; let's say `<c-w>+`.
    " Since the mapping command is recursive, `<c-w>+` could be remapped.
    " This is unexpected; we don't want that.
    "
    " Besides,  `a:rhs` can  be a  custom mapping  defined with  its own  set of
    " arguments (`<expr>`, `<silent>`, ...).
    " But you can't use them here because the other `<plug>` may not work with them.
    "}}}
    exe a:mode .. 'map '
        \ .. (a:flags =~# 'b' ? ' <buffer> ' : '')
        \ .. a:lhs
        \
        "\     <plug>(sm-exe:scrollwin:<c-g>j)
        "\     →     <c-x><c-e>
        \ .. ' ' .. plug_exe
        "\     <plug>(sm-show:scrollwin)
        "\     →     <sid>show_submode('scrollwin')
        \ .. plug_show
        "\     <plug>(sm-prefix:scrollwin)_____
        "\     →     <cmd>call <sid>on_leaving_submode()<cr>
        \ .. plug_prefix

    "     imap <plug>(sm-exe:scrollwin:<c-g>j) <c-x><c-e>
    exe a:mode .. (a:flags =~# 'r' ? 'map' : 'noremap')
        "\ use mapping arguments (`<buffer>`, `<expr>`, ...) according to flags passed to `#enter()`
        \ .. ' ' .. s:map_arguments(a:flags)
        \ .. ' ' .. plug_exe
        \ .. ' ' .. a:rhs

    "     ino <plug>(sm-show:scrollwin) <cmd>call <sid>show_submode('scrollwin')<cr>
    exe printf('%snoremap %s <cmd>call <sid>show_submode(%s)<cr>', a:mode, plug_show, string(a:name))

    "     ino <plug>(sm-prefix:scrollwin) <cmd>call <sid>on_leaving_submode()<cr>
    exe printf('%snoremap %s <cmd>call <sid>on_leaving_submode()<cr>', a:mode, plug_prefix)

    "     imap <plug>(sm-prefix:scrollwin)_____j <c-g>j
    exe a:mode .. 'map '
        \ (a:flags =~# 'b' ? ' <buffer> ' : '')
        \        plug_prefix .. s:last_key(a:lhs)
        \ .. ' ' .. a:lhs
endfu
"}}}1
" Util {{{1
fu s:map_arguments(flags) abort "{{{2
    return split(a:flags, '\zs')->map('get(s:FLAG2ARG, v:val, "")')->join()
endfu

fu s:last_key(lhs) abort "{{{2
    " If you need sth more reliable, try this:{{{
    "
    "     let lhs = matchstr(a:lhs, '<[^<>]\+>$')
    "     if !empty(lhs) && eval('"\' .. lhs .. '"') isnot# lhs
    "         return lhs
    "     else
    "         return a:lhs[-1:-1]
    "     endif
    "
    " The idea is that if `<[^<>]\+>$` has matched a special key, then we should
    " be able to translate it into sth different.
    " If we  can't, then  we didn't really  match a special  key, and  we should
    " ignore it.
    "}}}
    return matchstr(a:lhs, '<[^<>]\+>$\|.$')
endfu

fu s:on_leaving_submode() abort "{{{2
    " clear the command-line to erase the name of the submode
    if mode() =~# '^[iR]'
        let pos = getcurpos()
        redraw!
        call setpos('.', pos)
    else
        exe "norm! \<c-l>"
    endif
    return ''
endfu

fu s:show_submode(name, ...) abort "{{{2
    " The message may sometimes be erased unexpectedly.  Delaying it fixes the issue.{{{
    "
    " That happens, for example, with `i^x^e` and `i^x^y`.
    " For some reason, the scrolling of the window causes the command-line to be
    " redrawn;  it  should  not  happen  since  the  scrolling  occurs  *before*
    " `s:show_submode()` is invoked.
    " The only explanation I can find  is that, even though `i^x^e` is processed
    " immediately, the actual scrolling is delayed until the typeahead is empty...
    "
    " MWE:
    "
    "     $ vim -Nu NONE -S <(cat <<'EOF'
    "         set noshowmode
    "         ino <c-g>j <c-x><c-e><c-r>=Echo()<cr>
    "         fu Echo()
    "             echo 'YOU SHOULD SEE ME BUT YOU WONT'
    "             return ''
    "         endfu
    "         sil pu=range(&lines)
    "         startinsert
    "     EOF
    "     )
    "     " press 'C-g j'
    "}}}
    let when = a:0 ? 'now' : 'later'
    if when is# 'now'
        echohl ModeMsg
        echo '-- Submode: ' .. a:name .. ' --'
        echohl None
    else
        " don't try `SafeState`; it's not fired in insert mode
        call timer_start(0, {-> s:show_submode(a:name, 'now')})
    endif
endfu

