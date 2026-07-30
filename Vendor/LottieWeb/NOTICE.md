# Vendored lottie-web renderer

Source repository: <https://github.com/airbnb/lottie-web>

Lottie Lab bundles the SVG build from lottie-web `5.13.0`
(`bede03d25d232826e0c9dca1733d542d8a7754fb`) as a local reference renderer.
It is used when an animation contains Gaussian Blur (`ty: 29`), which is not
supported by lottie-ios.

lottie-web is distributed under the MIT License. See `LICENSE.md`.
