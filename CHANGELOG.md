# Changelog

## v0.8.0

* Updates
  * Support for subscribing after connecting to the MQTT server

## v0.7.3

* Updates
  * Remove Logger warnings for Elixir 1.15

* Fixes
  * Add `:clean_session` option support. This fixes issues with QoS 1 sessions

## v0.7.2

* Updates
  * Support querying the session's connection status

## v0.7.1

* Fixes
  * Added dialyzer flags :missing_return, :extra_return
  * Minor fixes to remove new dialyzer warnings
  * Updated CI to OTP 25

## v0.7.0

* Updated
  * BREAKING CHANGE: Jackalope no longer encodes or decodes MQTT message payloads.

## v0.6.0

* Updates
  * BREAKING CHANGE: Dynamic subscriptions are no longer supported
  * :infinity is no longer the default for publish work item TTL or work list bound
  * BREAKING CHANGE: The API for publishing is simplified; there's now only one publish call

* Fixes
  * Dynamic subscriptions were broken in failure and retry scenarios, removing support for them fixes that

## v0.5.1

* Updates
  * Uses backoff options

## v0.5.0

* Updates
  * Bumped tortoise311 to 0.11

## v0.4.2 - DEPRECATED

* Updates
  * All references to Tortoise are replaced by Tortoise311

## v0.4.1

* Updates
  * Now using tortoise311 forked from tortoise

## v0.4.0

* Updates
  * Session work list can be bounded to a set size

## v0.3.0

* Updates
  * Moved to Tortoise 0.10.0
  * Last-will message callbacks

## v0.2.0

* Bug fixes
  * Fix topic return type for `:payload_decode_error` - This is a breaking
    change if you're using it.
  * Reduce logging when everything is working fine

## v0.1.0

Initial release to hex.
