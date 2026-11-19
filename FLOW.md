# Flow-inspired desktop concept

`flow-preview/index.html` is an independent, browser-only Liquid Glass-style
visual prototype. Open it in a browser; the dock opens the compatibility panel,
the close button hides it, and the clock uses local time. No dependencies,
remote assets, tracking or external runtime are included. It is **not an OS**,
an ISO, a Windows shell, or a copy of the commercial FlowOS product.

## Compatibility reality

The prototype cannot run EXE, Linux binaries, APK, macOS apps or IPA files.
A future Windows-based implementation could run Windows apps natively, and could
optionally integrate WSL for supported Linux apps or a separately installed
Android runtime, subject to platform support and hardware. Neither offers
universal app compatibility. Running macOS applications or iOS IPA files has
platform, hardware, signing, DRM and licensing constraints; there is no general
legal/technical implementation promised here. Commercial FlowOS's claims are
not evidence of compatibility in this project.

## Next engineering decisions

A real multi-platform OS would be a separate multi-stage project: agree on host
kernel (Linux versus Windows), target hardware and application priorities;
prototype isolated compatibility runtimes; audit dependencies and licenses;
test a matrix of specific applications; then build and validate a bootable image.
A browser mockup is a design foundation only. Its resource usage cannot predict
that of a future operating system. No binary compatibility, performance, memory
or hardware-support claims have been verified.
