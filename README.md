# FireBan Distribution

This repository is the public binary distribution channel for FireBan and
FireNode. It intentionally contains no application source code.

It provides:

- public installers and the Xray helper used by FireNode;
- release manifests for stable and dev binaries;
- checksums and GitHub Release assets published by the private source repos.

Install FireBan development builds with:

```bash
curl -sL https://raw.githubusercontent.com/firegoood/FireBan-Release/main/scripts/rebecca/fireban-binary.sh | sudo bash -s -- install --dev
```

Install FireNode development builds with:

```bash
curl -sL https://raw.githubusercontent.com/firegoood/FireBan-Release/main/scripts/rebecca/firenode-binary.sh | sudo bash -s -- install --dev
```

The private FireBan and FireNode repositories publish only tested binary
artifacts and manifest metadata here through GitHub Actions.
