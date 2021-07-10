vim9script noclear

# Init {{{1

var timer_id: number
var submode2bracket_key: dict<string>
var pos_before_exe: list<number>

# A string to hide internal key mappings from the `'showcmd'` area.
# https://github.com/kana/vim-submode/issues/3
#
# We use no-break spaces (`U+00A0`), because:
#
#    - in the showcmd area, a normal space (U+0020) is rendered as "<20>" since Vim 7.4.116
#    - in insert mode, in the cell right after the cursor, a normal spaced is rendered as " "
#    - `U+00A0` is rendered as an invisible glyph if `'encoding'` is set to one of Unicode encodings
#
# `U+00A0` is really rendered as an *invisible* glyph; not " ".
# If it was rendered as " ", when  you're in a submode entered from insert mode,
# the character after the cursor would be hidden until the timeout.
# That's not the case; it always remains visible.

# Why `5`?{{{
#
# It seems the command-line only displays the last 10 bytes of the typeahead buffer.
# And a no-break space takes 2 bytes, so we need 5 of them to occupy the 10 bytes.
#}}}
const STEALTH_TYPEAHEAD: string = repeat('<char-0xa0>', 5)
#                                         ├─────────┘
#                                         └ `:help <Char>`

const FLAG2ARG: dict<string> = {
    b: '<buffer>',
    e: '<expr>',
    n: '<nowait>',
    s: '<silent>',
    S: '<script>',
}

for mode: string in ['i', 'n', 'o', 's', 't', 'v', 'x']
    execute mode .. 'noremap <Plug>(submode-before-exe)'
        .. ' <Cmd>call <SID>BeforeExe()<CR>'
endfor

# Interface {{{1
def submode#enter( #{{{2
    name: string,
    modes: string,
    flags: string,
    lhs: string,
    rhs: string,
)
    # What the function does can be boiled down to this:{{{
    #
    #     imap <C-G>j <C-X><C-E><Plug>(prefix)
    #     imap <Plug>(prefix)j <C-G>j
    #     inoremap <Plug>(prefix) <Nop>
    #
    #     imap <C-G>k <C-X><C-Y><Plug>(prefix)
    #     imap <Plug>(prefix)k <C-G>k
    #
    # In this example, we  want `C-g j` to enter a submode  from insert mode, in
    # which we can simply press `j` to scroll the window one line up.
    #
    # Note that this works in a simple  test, but it's brittle because some keys
    # can be  wrongly remapped.  Our  current implementation uses  more `<Plug>`
    # mappings to be more robust.
    #
    # For some more details, see:
    # https://vi.stackexchange.com/a/24403/17449
    #}}}
    # Here is an example of invocations for this function:{{{
    #
    #     call submode#enter('scrollwin', 'i', '', '<C-G>j', '<C-X><C-E>' )
    #     call submode#enter('scrollwin', 'i', '', '<C-G>k', '<C-X><C-Y>' )
    #                         │            │   │    │         │
    #                         │            │   │    │         └ rhs: how the keys must be expanded
    #                         │            │   │    └ lhs: the keys to press to enter 'scrollwin'
    #                         │            │   └ flags: no flag
    #                         │            └ mode: 'scrollwin' can be entered from insert mode
    #                         └ name: the submode is named 'scrollwin'
    #}}}
    # And here are the resulting *recursive* mappings:{{{
    #
    #     <C-G>j  <Plug>(sm-exe:scrollwin:<C-G>j)<Plug>(sm-show:scrollwin)<Plug>(sm-prefix:scrollwin)_____
    #     <C-G>k  <Plug>(sm-exe:scrollwin:<C-G>k)<Plug>(sm-show:scrollwin)<Plug>(sm-prefix:scrollwin)_____
    #             ├─────────────────────────────┘├───────────────────────┘├──────────────...
    #             │                              │                        └ type an ad-hoc prefix
    #             │                              │ so that you can repeat commands with 1 keypress
    #             │                              │ (here 'j' and 'k' can repeat '<C-G>j' and '<C-G>k')
    #             │                              │
    #             │                              └ show you the name of the submode you're in (here 'scrollwin')
    #             │
    #             └ execute the desired command (here C-x C-y)
    #
    #     <Plug>(sm-prefix:scrollwin)_____j  <C-G>j
    #     <Plug>(sm-prefix:scrollwin)_____k  <C-G>k
    #     ├──────────────────────────────┘│  ├────┘
    #     │                               │  └ repeat the whole process:
    #     │                               │
    #     │                               │      - execute desired command
    #     │                               │      - show name of the submode
    #     │                               │      - feed the ad-hoc prefix automatically
    #     │                               │
    #     │                               └ *this* is meant to be typed interactively
    #     │
    #     └ you'll never type this ad-hoc prefix interactively,
    #       it will always be fed to the typeahead automatically from a previous mapping expansion,
    #       but it will never be executed immediately because there will always be an ambiguity
    #       (another mapping is going to be installed with this prefix as its entire lhs)
    #
    # Note  that  in reality,  the  sequences  of  underscores are  replaced  by
    # sequences of no-break  spaces to be invisible on the  command-line (and on
    # the cursor cell in insert mode).
    #}}}
    #   As well as the *non*-recursive mappings:{{{
    #
    #     <Plug>(sm-exe:scrollwin:<C-G>j)  <C-X><C-E>
    #     <Plug>(sm-exe:scrollwin:<C-G>k)  <C-X><C-Y>
    #
    #     <Plug>(sm-show:scrollwin) <Cmd>call <SNR>123ShowSubmode('scrollwin')<CR>
    #
    #     <Plug>(sm-prefix:scrollwin)_____  <Cmd>call <SNR>123OnLeavingSubmode()<CR>
    #}}}
    for mode: string in modes
        InstallMappings(name, mode, flags, lhs, rhs)
        # Problem: It's cumbersome to repress `]x` to enter a submode after having left it.
        # Solution:{{{
        #
        # Let us  press `]]` to re-enter  the last submode which  was entered by
        # pressing a sequence starting with a square bracket.
        # To  implement this  feature, we  need to  remember –  for any  given
        # submode – the last keys after the square bracket:
        #
        #     {
        #          arglist: 'a',
        #          lightness: 'ol',
        #          ...
        #     }
        #}}}
        if mode == 'n' && lhs[0] == ']'
            submode2bracket_key[name] = lhs[1 :]
        endif
    endfor
enddef
#}}}1
# Core {{{1
def InstallMappings( #{{{2
    name: string,
    mode: string,
    flags: string,
    lhs: string,
    rhs: string
)
    # Why do you include `name` after the plug key?{{{
    #
    # The sequence of characters following the plug key must be unique enough.
    # For example, you could use the  same key (e.g. `C-g j`) to enter different
    # submodes from different modes (e.g.  insert and normal modes), and execute
    # different  commands.  You  can't use  the  same lhs  to execute  different
    # commands.
    #
    # You could use `mode` instead of `name`,  but if you have an issue with
    # a submode,  it's easier to  find all the  relevant mappings when  they all
    # share a telling name:
    #
    #     <Plug>(sm-exe:scrollwin:<C-G>j) * <C-X><C-E>
    #                   ^-------^
    #                   easy to find
    #
    #     <Plug>(sm-exe:i:<C-G>j) * <C-X><C-E>
    #                   ^
    #                   hard to find
    #}}}
    var plug_exe: string = printf('<Plug>(sm-exe:%s:%s)', name, lhs)
    var plug_show: string = printf('<Plug>(sm-show:%s)', name)
    var plug_prefix: string = printf('<Plug>(sm-prefix:%s)%s', name, STEALTH_TYPEAHEAD)

    # Install mapping on `lhs` to make it enter a submode.
    # The mapping must be recursive, because its rhs contains `<Plug>` keys.
    # Why bother with `plug_exe`?  Why not just use `rhs` directly?{{{
    #
    # Suppose that `rhs` is a built-in command; let's say `<C-W>+`.
    # Since the mapping command is recursive, `<C-W>+` could be remapped.
    # This is unexpected; we don't want that.
    #
    # Besides,  `rhs` can  be a  custom mapping  defined with  its own  set of
    # arguments (`<expr>`, `<silent>`, ...).
    # But you can't use them here because the other `<Plug>` may not work with them.
    #}}}
    # TODO: Try to not install this mapping from here.{{{
    #
    # It makes  debugging harder, because  `:verbose` cannot tell us  from where
    # the original mapping is really installed.
    # Instead, we  should return the info  (possibly via a string),  used by the
    # caller (e.g. via `:execute`).
    #
    # Problem: OK, so this function should return sth like a string.
    # In turn, `submode#enter()` would return this string.
    # But the latter can iterate over several modes.
    # We can't return for every single one of them.
    #}}}
    execute mode .. 'map '
        .. (flags =~ 'b' ? ' <buffer> ' : '')
        .. lhs
        .. ' '
        .. '<Plug>(submode-before-exe)'
        #     <Plug>(sm-exe:scrollwin:<C-G>j)
        #     →     <C-X><C-E>
        .. plug_exe
        #     <Plug>(sm-show:scrollwin)
        #     →     <SID>ShowSubmode('scrollwin')
        .. plug_show
        #     <Plug>(sm-prefix:scrollwin)_____
        #     →     <Cmd>call <SID>OnLeavingSubmode()<CR>
        .. plug_prefix

    #     imap <Plug>(sm-exe:scrollwin:<C-G>j) <C-X><C-E>
    execute mode .. (flags =~ 'r' ? 'map' : 'noremap')
        # use mapping arguments (`<buffer>`, `<expr>`, ...) according to flags passed to `#enter()`
        .. ' ' .. MapArguments(flags)
        .. ' ' .. plug_exe
        .. ' ' .. rhs

    #     inoremap <Plug>(sm-show:scrollwin) <Cmd>call <SID>ShowSubmode('scrollwin')<CR>
    execute printf('%snoremap %s <Cmd>call <SID>ShowSubmode(%s)<CR>', mode, plug_show, string(name))

    #     inoremap <Plug>(sm-prefix:scrollwin) <Cmd>call <SID>OnLeavingSubmode()<CR>
    execute printf('%snoremap %s <Cmd>call <SID>OnLeavingSubmode()<CR>', mode, plug_prefix)

    #     imap <Plug>(sm-prefix:scrollwin)_____j <C-G>j
    execute mode .. 'map '
        .. (flags =~ 'b' ? ' <buffer> ' : '')
        .. plug_prefix .. LastKey(lhs)
        .. ' ' .. lhs
enddef

def BeforeExe() #{{{2
    # need this to decide later whether we should redraw the status line
    pos_before_exe = getpos('.')

    # if the mapping encounters an error, we should automatically leave the submode
    if timer_id != 0
        timer_stop(timer_id)
    endif
    timer_id = timer_start(0, (_) => CheckMappingHasWorked())
enddef

def CheckMappingHasWorked() #{{{2
    # We're still in the middle of a mapping, so we're probably still in a submode.
    if state() =~ 'm'
        return
    endif
    # The mapping has somehow failed; we're no longer in a submode.
    OnLeavingSubmode()
    timer_stop(timer_id)
    timer_id = 0
enddef

def OnLeavingSubmode() #{{{2
    # clear the command-line to erase the name of the submode
    if mode() =~ '^[iR]'
        var pos: list<number> = getcurpos()
        echo ''
        setpos('.', pos)
    else
        execute "normal! \<C-L>"
    endif
enddef

def ShowSubmode(submode: string, when = 'later') #{{{2
# Don't try to use a popup.{{{
#
# It would wrongly remain open if we leave a submode by pressing `<C-C>`.
#
# Besides, `:echo` better emulates Vim's default behavior when printing a mode.
#}}}

    # The message may sometimes be erased unexpectedly.  Delaying it fixes the issue.{{{
    #
    # That happens, for example, with `i^x^e` and `i^x^y`.
    # For some reason, the scrolling of the window causes the command-line to be
    # redrawn;  it  should  not  happen  since  the  scrolling  occurs  *before*
    # `ShowSubmode()` is invoked.
    # The only explanation I can find  is that, even though `i^x^e` is processed
    # immediately, the actual scrolling is delayed until the typeahead is empty...
    #
    # MWE:
    #
    #     set noshowmode
    #     inoremap <C-G>j <C-X><C-E><C-R>=Echo()<CR>
    #     function Echo()
    #         echo 'YOU SHOULD SEE ME BUT YOU WONT'
    #         return ''
    #     endfunction
    #     silent put =range(&lines)
    #     startinsert
    #     " press 'C-g j'
    #}}}
    if when == 'now'
        echohl ModeMsg
        echo '-- Submode: ' .. submode .. ' --'
        echohl None
    else
        # don't try `SafeState`; it's not fired in insert mode
        timer_start(0, (_) => ShowSubmode(submode, 'now'))
    endif

    # TODO: What follows is irrelevant with regards to the function name.
    # Maybe we  need an additional `<Plug>(submode-after-exe)`  mapping which we
    # could use to run arbitrary code after we've run a command in a submode.

    # Sometimes, the status line is not redrawn.  It should.{{{
    #
    # For example, when we traverse the changelist, it is jarring to not see the
    # position always updated in the status line.
    #}}}
    if getpos('.') != pos_before_exe
        redrawstatus
    endif

    # if we  leave a  submode, let us  re-enter it with  `]]` (provided  that we
    # entered it with a sequence starting with `]`)
    if mode(true) == 'n' && submode2bracket_key->has_key(submode)
        execute 'nmap ]] ]' .. submode2bracket_key[submode]
        execute 'nmap [[ [' .. submode2bracket_key[submode]
    endif
enddef
#}}}1
# Util {{{1
def MapArguments(flags: string): string #{{{2
    return split(flags, '\zs')
        ->map((_, v: string) => get(FLAG2ARG, v, ''))
        ->join()
enddef

def LastKey(lhs: string): string #{{{2
    # Special Case: Entering a submode via a sequence starting with a bracket, like `]x`.{{{
    #
    # In that  case, we probably  want to repeat the  key with the  bracket, not
    # with the  last key.  This  is convenient, for  example, for `]a`  and `[a`
    # which traverse the arglist:
    #
    #     press ]a to jump to the next argument
    #     press ]  to jump to the next argument again
    #     press [  to jump to the previous argument
    #     ...
    #}}}
    if lhs =~ '^\['
        return '['
    elseif lhs =~ '^]'
        return ']'
    elseif lhs =~ '^<\a\%(.*>\)\@!'
        return '<'
    elseif lhs =~ '^>'
        return '>'
    endif

    # If you need sth more reliable, try this:{{{
    #
    #     var special_key: string = lhs->matchstr('<[^<>]\+>$')
    #     if !empty(special_key) && eval('"\' .. special_key .. '"') != special_key
    #         return special_key
    #     else
    #         return lhs[-1]
    #     endif
    #
    # The idea is that if `<[^<>]\+>$` has matched a special key, then we should
    # be able to translate it into sth different.
    # If we  can't, then  we didn't really  match a special  key, and  we should
    # ignore it.
    #}}}
    return lhs->matchstr('<[^<>]\+>$\|.$')
enddef

