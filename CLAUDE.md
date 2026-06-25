# Project notes

## Slide deck (separate repo)

The presentation built from this benchmark lives **outside** this repo, in the
`presentations` repo:

- Deck: `/Users/tcadman/git-repos/presentations/armadillo-opal-comparison/slides.md`
- It is a [Slidev](https://sli.dev) deck using the shared theme at
  `/Users/tcadman/git-repos/presentations/theme` (CSS vars in
  `theme/styles/index.css`; layouts in `theme/layouts/`).
- Custom diagram components live in
  `presentations/armadillo-opal-comparison/components/` — e.g. `PollPenalty.vue`
  (DSI polling-sleep measurement caveat). The visual style mirrors
  `RoundTrips.vue` in the `eos/sprint-257` deck (the server round-trip diagram).

When asked to update "the slide deck" or add slides/diagrams about this
benchmark, edit files under `presentations/armadillo-opal-comparison/`, not this repo.
