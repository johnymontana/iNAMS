# Vendored OpenAPI spec

`openapi.json` is a copy of `frontend/public/openapi.json` from the
`project-gaylord` monorepo, used by CI to contract-check the hand-written
Swift client's route constants against the backend's documented paths.

- Pinned to project-gaylord commit: `92a97f58b76babfe09bef663c89ff597011d2fcc`
  (branch `inams`), **plus** the then-uncommitted `POST /v1/messages/search`
  workspace-wide message search endpoint added for iNAMS.
- Refresh deliberately: run `make generate-spec` in the monorepo, copy the
  file here, and update this pin.
