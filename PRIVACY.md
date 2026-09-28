# Hermes Go Privacy Policy

Effective September 28, 2026

Hermes Go is a client for a Hermes gateway that you or your organization run.
The publisher of Hermes Go does not operate a hosted Hermes service and does
not receive your gateway credentials, conversations, attachments, or health
data.

## Data the app handles

Hermes Go may handle the following information when you use the corresponding
feature:

- Gateway address and authentication session data needed to connect to the
  gateway you choose.
- Conversations, attachments, bot settings, jobs, and other content exchanged
  with that gateway.
- On iPhone and iPad, Apple Health categories you explicitly authorize,
  including activity, sleep, heart, vital-sign, body-measurement, mobility,
  workout, mindfulness, and nutrition samples.
- Microphone audio and speech-recognition input when you use dictation, photos
  you select or capture for an attachment, and notification data when you
  enable notifications.

Hermes Go does not use health data for advertising, marketing, profiling, or
data mining, and it never writes to the Apple Health app.

## Where data goes

The app sends gateway content directly to the gateway address you configure.
Apple Health samples are sent only after you enable Apple Health sync and grant
iOS read permission. They are stored on that authenticated gateway so a
health-capable bot can answer a bounded question or summarize a trend.

Your gateway may send conversations, attachments, or a requested health
summary to model providers, tools, or services configured by the gateway
owner. Those services are selected and controlled outside Hermes Go and are
governed by their own privacy terms. Hermes Go does not independently send
your content to an AI provider and does not receive it on a publisher-operated
server.

Apple may process dictation through its Speech framework according to your
device settings and Apple's terms.

## On-device storage and security

Hermes Go stores connection metadata, encrypted session cookies, preferences,
and a local conversation cache on your device. Authentication sessions are
stored using platform-provided secure storage. Network traffic uses the HTTP,
HTTPS, and WebSocket configuration of the gateway URL you choose; you are
responsible for securing and administering that gateway.

This release contains no advertising, attribution, or analytics SDK and does
not track you across apps or websites.

## Retention, deletion, and your choices

Data on a self-hosted gateway remains subject to that gateway's configuration
and the gateway owner's retention practices.

- Turning Apple Health sync off stops future uploads but does not delete data
  already stored on the gateway.
- **Delete gateway health data** in Settings permanently deletes the Apple
  Health samples held by the Hermes Apple Health plugin for that gateway and
  clears the app's local Apple Health sync state.
- Disconnecting a gateway removes its saved connection and authentication data
  from the app. It does not automatically delete content stored by the
  gateway.
- You can change or revoke Hermes Go's Apple Health permissions at any time in
  the Apple Health app or iOS Settings.

Because the publisher does not receive or control data stored on your gateway,
requests concerning that data must be handled by you or the operator of that
gateway.

## Children

Hermes Go is intended for developers and technical users who administer a
Hermes gateway. It is not directed to children.

## Changes and contact

Material changes will be published in this repository with an updated
effective date. Questions or privacy requests concerning Hermes Go itself can
be filed at <https://github.com/TheTom/hermes-go/issues>.
