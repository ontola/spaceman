//! Platform-independent core: scanning, suggestions and the protect list.
//! Nothing in here knows about Flutter; see `crate::api` for the bridge.

pub mod cache;
pub mod privacy;
pub mod protect;
pub mod rules;
pub mod scan;
pub mod tree;
