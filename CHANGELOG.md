# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [0.4.1] - 2025-06-29

### Fixed

- [`PlugHTTPCache`] URLs with RFC3986 non-conforming characters (such as `[`, `]`)
no longer make `http_cache` crash

## [0.4.0] - 2025-05-17

### Added

- [`PlugHTTPCache`] The `stale-while-revalidate` cache-control directive is now supported
- [`PlugHTTPCache`] The conn was added to telemetry events' metadata

### Changed

- [`PlugHTTPCache`] Elixir 1.18+ is required
- [`PlugHTTPCache.StaleIfError`] `stale-if-error` is now supported only through the use
of this cache-control directive. See the update module's documentation

## [0.3.1] - 2023-09-10

### Added

- [`PlugHTTPCache`] The `conn` is added to telemetry events' metadata

### Changed

- [`PlugHTTPCache`] When the request body is parsed and there are no parameters, it
is set to the empty string `""`

## [0.3.0] - 2023-06-22

### Changed

- [`PlugHTTPCache`] Make `http_cache` an optional depedency

## [0.2.0] - 2023-04-25

### Changed

- [`PlugHTTPCache`] Update to use `http_cache` `0.2.0`
- [`PlugHTTPCache`] Options are now a map (was previously a keyword list)

## [0.1.0] - 2022-08-21

Initial release
