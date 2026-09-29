# kakoune-jj

[jj](https://jj-vcs.dev/) plugin for [Kakoune](https://kakoune.org/) (version `v2026.04.12` or higher).

## Installation

```shell
$ git clone https://github.com/krobelus/kakoune-jj ~/.config/kak/autoload/kakoune-jj
$ kak -e 'doc jj'
```

## Features

- `:jj` is a comprehensive and unopinionated wrapper around jj CLI
- dynamic completions (commit IDs, change IDs, branch names, files)
- colored output if [kak-ansi](https://github.com/eraserhd/kak-ansi/) is installed
- `:jj (diff|show) --git` are compatible with tools like `:diff-jump` (mapped to `<ret>` by default) and `:git blame`
- `:jj split` to split out the selected part of a commit

## Example mappings

```kak
declare-user-mode jj
map global user j %{:enter-user-mode jj<ret.} -docstring 'jj...'
map global jj d %{:jj describe } -docstring 'jj describe...'
map global jj e %{:jj edit } -docstring 'jj edit...'
map global jj i %{:jj split<ret>} -docstring 'jj split'
map global jj n %{: jj new } -docstring 'jj new...'
map global jj q %{:jj squash } -docstring 'jj squash...'
map global jj r %{:jj rebase } -docstring 'jj rebase...'
map global jj s %{: jj show --git } -docstring 'jj show...'

# Inside a ":jj log" buffer (using the default template), this mapping allows
# to quickly insert change IDs into the command line.
# For example, select a few commits and type ":jj rebase -A trunk() -r <c-t>"
map global prompt <c-t> %{<a-semicolon>:eval -draft my-jj-select-revisions<ret><c-r><c-r>} -docstring 'insert selected commits into the prompt'
define-command my-jj-select-revisions %{
	evaluate-commands %{
		try %{
			execute-keys %{<a-/>^(?:commit|Change ID:) \S+<ret>}
			execute-keys %{1s^(?:commit|Change ID:) (\S+)<ret>}
		} catch %{
			execute-keys %{<a-s><a-l><semicolon><a-/>^\h*(?:[│ ])*[@◆○×](?:\h*│)*\h*\b[a-z]+(?:/\d+)?<ret>}
			execute-keys %{1s^\h*(?:[│ ])*[@◆○×](?:\h*│)*\h*\b([a-z]+(?:/\d+)?)<ret>}
		}
	}
	set-register r %sh{
		eval "set -- $kak_quoted_selections"
		printf %s\\n "$@" | paste -d '|' -s
	}
} -docstring %{
	In a buffer created by ":jj log" (using the default template),
	select all change IDs around all selections.
	In a buffer created by ":jj show", ":git show" etc., select the commit ID.
	Finally, set the 'r' register to the set of all selected commits.
}
```

## Contributing

Send feedback and patches to [~krobelus/kakoune@lists.sr.ht](mailto:~krobelus/kakoune@lists.sr.ht) (see
[public archives](https://lists.sr.ht/~krobelus/kakoune)) or use GitHub.
