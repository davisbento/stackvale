# Deployment

Stackvale uses GitHub Actions to build macOS releases and Netlify to deploy the
website. The GitHub repository remains private; the DMG is served publicly by
the Netlify site.

## Release a new version

Create and push a version tag from `main`:

```bash
git tag -a v0.4.0 -m "Release v0.4.0"
git push origin main
git push origin v0.4.0
```

Replace `v0.4.0` with the next version number.

Pushing a tag that matches `v*` starts
`.github/workflows/release.yml`. The workflow:

1. Builds the app and DMG with `make dmg`.
2. Copies the DMG to `web/public/downloads/Stackvale.dmg`.
3. Commits and pushes the updated DMG to the default branch.
4. Creates a GitHub Release and attaches `dist/Stackvale.dmg`.

The commit pushed in step 3 triggers the Netlify deployment. The public
download URL is:

```text
https://<site-domain>/downloads/Stackvale.dmg
```

## Build the DMG locally

Run the following command from the repository root:

```bash
make dmg
```

This builds the Release configuration, creates `dist/Stackvale.dmg`, and
updates `web/public/downloads/Stackvale.dmg`.

## Important details

- Keep `web/public/downloads/Stackvale.dmg` in the repository. Netlify serves
  files in `web/public` as public static assets.
- Do not link the website directly to a private GitHub Release. Visitors are
  not authenticated to GitHub and cannot download private release assets.
- Do not put a GitHub token in website code or a public download URL.
- Commit messages must follow the Conventional Commits format.
- The website download is public. Use object storage with signed URLs instead
  if downloads must be restricted or if release files become large.
