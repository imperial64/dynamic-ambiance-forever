# Releasing

For the maintainer. Releases are built by the
[BigWigs packager](https://github.com/BigWigsMods/packager) in GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)), configured by
[`.pkgmeta`](.pkgmeta). Pushing a tag is the whole release; nothing is built by hand.

Statements below about the packager's behaviour were checked against its `release.sh` as
fetched on 2026-09-25. It changes; recheck when something looks off.

## What a release contains

The zip is `DynamicAmbiance-<tag>-forever.zip`, holding one folder, `DynamicAmbiance/`: the
`.toc`, the files it lists (including `UI\`), and `LICENSE`. Everything else in the
repository is excluded by `.pkgmeta`. The packager replaces `@project-version@` in the `.toc`
with the tag, so the in-game version reads `v0.3.0`. A copy installed straight from the repo
with `scripts/install-addon.ps1` still shows the literal keyword in the addon list; that is
expected.

The release notes are [`CHANGELOG.md`](CHANGELOG.md), used as written (`manual-changelog`).

## Cutting a release

1. Add an entry to the top of `CHANGELOG.md`, written for players, and set
   `Serialize.ADDON_VERSION` in `addons/DynamicAmbiance/Serialize.lua` to the same version
   (the fallback when the `.toc` keyword is not replaced).
2. Run the tests (`lua tests/run.lua`) and commit.
3. Tag with an **annotated** tag and push it:

   ```
   git tag -a v0.3.0 -m "v0.3.0"
   git push origin v0.3.0
   ```

4. Watch the run under the repository's **Actions** tab. When it finishes, the zip is on the
   [Releases](https://github.com/imperial64/dynamic-ambiance-forever/releases) page and on
   every site that is set up (below).

A tag containing `alpha` or `beta` is published as that release type; a plain `vX.Y.Z` is a
full release.

If the run fails with "Resource not accessible by integration", the workflow token cannot
write: in the repository's **Settings → Actions → General → Workflow permissions**, choose
"Read and write permissions".

## One-time setup: the addon sites

Only you can do these. Until they are done, the packager **skips** those uploads and a tag
makes only the GitHub Release. The check is in `release.sh`: each upload returns straight
away, without an error, when its project ID is missing from the `.toc` or its token is empty.
Setting a token without the ID (or the other way round) is harmless.

### CurseForge (supported for Forever)

The packager uploads Forever builds to CurseForge under its own game-version type (game id
88568 in `release.sh`).

1. Create the project on CurseForge. Its numeric **Project ID** is on the project's overview
   page.
2. Create an API token in your CurseForge account's API tokens page.
3. Add the ID to `addons/DynamicAmbiance/DynamicAmbiance.toc`, below `## X-Credits`, in
   exactly this form (the number is yours; the packager only uploads when it is all digits):

   ```
   ## X-Curse-Project-ID: 123456
   ```

4. Add the token as a repository secret named `CF_API_KEY` (below).

### Wago (supported for Forever)

`release.sh` maps Forever to Wago's `forever` game type, and Wago's
`https://addons.wago.io/api/data/game` listed `forever` with patch `1.60.1` on 2026-09-25.

1. Create the project on <https://addons.wago.io>. Note its **Wago project ID**, a short
   code of letters and digits.
2. Create an API token in your Wago account.
3. Add the ID to the `.toc`, below `## X-Credits`:

   ```
   ## X-Wago-ID: abcd1234
   ```

4. Add the token as a repository secret named `WAGO_API_TOKEN`.

### WoWInterface: not supported by the packager for Forever yet

`release.sh` (fetched 2026-09-25, `upload_wowinterface`) has no WoWInterface game type for
Forever: it prints `No WoWInterface game type match for "forever" ... ignoring`, finds no
game version, reports "Skipping upload to WoWInterface" **and fails the run**. So do not add
an `## X-WoWI-ID:` line to the `.toc` until the packager supports Forever there. The
`WOWI_API_TOKEN` line in the workflow is harmless without the ID and can stay. To publish on
WoWInterface meanwhile, upload the GitHub Release zip by hand.

### Adding the secrets

In the GitHub repository: **Settings → Secrets and variables → Actions → New repository
secret**. Names, exactly:

| Secret | For |
|---|---|
| `CF_API_KEY` | CurseForge |
| `WAGO_API_TOKEN` | Wago |
| `WOWI_API_TOKEN` | WoWInterface, once the packager supports Forever there |

`GITHUB_TOKEN`, used for the GitHub Release, is provided by GitHub and needs no setup.

After adding an ID to the `.toc`, commit it; the next tag uploads to that site. Once a site
listing exists, link it in the README's Install section.

## Checking a package locally

Without uploading, from Git Bash. The packager leaves out files git does not track, so run it
in a clone, or commit first. Keep `release.sh` outside the repository:

```
curl -s -o ~/release.sh https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh
cd path/to/dynamic-ambiance-forever
bash ~/release.sh -d -z      # -d: no upload, -z: no zip (Git Bash has no zip)
```

The result is in `.release/DynamicAmbiance/`, which is git-ignored. It should hold exactly
the `.toc`, the files the `.toc` lists and `LICENSE`.
