# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [0.3.1] - 2023-09-10

### Changed

- [`TeslaHTTPCache`] When the request body is parsed and there are no parameters, it
is set to the empty string `""`

## [0.3.0] - 2023-06-22

### Changed

- [`TeslaHTTPCache`] Make `http_cache` an optional depedency

## [0.2.0] - 2023-04-25

### Changed

- [`PlugHTTPCache`] Update to use `http_cache` `0.2.0`
- [`PlugHTTPCache`] Options are now a map (was previously a keyword list)

## [0.1.0] - 2022-08-21

Initial release
