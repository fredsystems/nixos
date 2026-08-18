# Renders the fully-generated `.gitconfig` content shared by every user.
#
# Used by modules/base/home.nix (primary user) and
# hosts/linux/fredvps/nik-home.nix (the "nik" secondary user, who is not
# reachable via the primary user's verbose_name / github_email specialArgs).
{
  name,
  email,
}:
''
  [filter "lfs"]
      required = true
      clean = git-lfs clean -- %f
      smudge = git-lfs smudge -- %f
      process = git-lfs filter-process

  [user]
      name = ${name}
      email = ${email}

  [commit]
      gpgsign = false

  [gpg]
      program = /run/current-system/sw/bin/gpg
      format = ssh

  [core]
      pager = delta

  [interactive]
      diffFilter = delta --color-only

  [delta]
      navigate = true
      side-by-side = true

  [merge]
      conflictstyle = diff3

  [diff]
      colorMoved = default
  [include]
      path = ~/.config/git/signing.conf
''
