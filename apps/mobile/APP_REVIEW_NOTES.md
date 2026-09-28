# App Review Notes for Hermes Go

Two paste blocks. No em dashes anywhere, because App Store Connect mangles
them. The Notes block is kept under the 4000 character limit of the App
Review Information field.

---

## BLOCK A: paste into App Review Information, then Notes

<!-- BEGIN NOTES BLOCK -->
WHAT THIS APP IS

Hermes Go is a client for a Hermes agent gateway the user runs. We operate no
backend. It is intended for developers and technical users who self-host an
agent.

DEMO ACCESS (no server required)

A sample workspace is built into the app, so review needs no server.
1. Launch the app.
2. In "Gateway base URL", enter: demo.hermes.go
3. Tap Continue.
4. Username: demo
5. Password: demo
6. Tap Sign In.

Then open a seeded chat from the top-left menu, send a message, switch models,
open Bots, open Jobs and pause a job, and open Settings.

The sample runs on-device at 127.0.0.1; no network call leaves the device. It
is available to every user and marked with a "Sample" chip.

BOTS

A bot is a name, model and instructions stored on the user's gateway. The app
lists bots and opens their server-owned conversations.

APPLE HEALTH

The initial connection screen and Settings both identify "Apple Health" and
open its disclosure. The feature is off by default. It remains visible in the
sample workspace, where its controls are disabled and no sample leaves the
device.

On a real gateway, enabling sync opens the standard iOS permission sheet. The
user chooses categories. Hermes Go reads only, never writes to Apple Health,
uses HealthKit, and does not use CareKit.

Authorized samples go to the user's authenticated gateway. A requested summary
may go to the model provider configured by that gateway. Nothing is sent to
the publisher, or used for advertising or marketing. Turning sync off stops
future uploads. "Delete gateway health data" separately deletes the gateway
copy and local sync state.

ACCOUNTS, PURCHASES, CONTENT

We run no account system. Credentials come from the user's gateway. There are
no purchases or shared user-generated content. Chats are private to the user
and their server.

PERMISSIONS

Camera/photos attach images; microphone and speech recognition provide
dictation; local-network access reaches the user's gateway; Apple Health is
covered above. Permissions are optional and requested in context. The app
requests no location, contacts or calendar access and performs no tracking.

EXTERNAL SERVICES

The app contacts the gateway the user enters. It has no analytics, advertising,
crash-reporting, tracking or payment SDK. AI services are configured on that
gateway. Apple speech recognition supports dictation and text to speech reads
replies aloud.

REGIONS AND REGULATED INDUSTRY

The app is the same in all regions, is localized in nine languages, provides
no regulated service, and includes no protected third-party material.

NO VPN FUNCTIONALITY

This is not a VPN and creates no tunnel. It does not link NetworkExtension, use
NEVPNManager or NETunnelProvider, request a VPN entitlement, or bundle a
tunneling library. It only makes HTTP(S)/WebSocket requests to the entered
gateway, including ordinary local-network access on the user's LAN.
<!-- END NOTES BLOCK -->

---

## BLOCK B2: reply to the Guideline 2.1 new-app information request

Answers the seven numbered items. Send with the screen recording attached.

<!-- BEGIN INFO REQUEST BLOCK -->
Thank you. Answers to all seven items follow.

1. SCREEN RECORDING

Attached. Captured on a physical iPhone 17 Pro, it shows launch, sample sign-in,
chat streaming with a tool call, a new chat, model switching, a scheduled job,
and Settings.

The following flows are absent because the app does not have them:
- No account registration and no account deletion. We operate no account
  system. The username and password belong to the server the user runs.
- No purchases, subscriptions or paid content of any kind.
- No user-generated content shared between users, so there is no reporting or
  blocking mechanism to show. A chat is private to the user and their own
  server.
- Permission prompts appear when their feature is first used. There is no App
  Tracking Transparency prompt because the app does no tracking.

2. DEVICES AND OPERATING SYSTEMS TESTED

- iPhone 17 Pro, iOS 27.0, physical device. Primary test device.
- iPad Air 11-inch (M4), iPadOS 27.0, Simulator. The full reviewer flow above
  was verified here as well, since your previous review used an iPad Air.

3. WHAT THE APP DOES, AND FOR WHOM

Hermes Go is a phone client for the open-source Hermes agent gateway the user
self-hosts on a home server, workstation or VPS.

It lets users reach that agent from a phone, stream replies, and review
scheduled jobs away from their desk.

Target audience is developers and technical users who already self host a
Hermes agent. It is not a consumer chatbot and provides no AI service of its
own.

4. SETUP AND ACCESS

For review, use the built-in sample: enter demo.hermes.go, tap Continue, use
username demo and password demo, then tap Sign In.

Real users enter their gateway address and credentials. No sample file is
required.

5. EXTERNAL SERVICES, TOOLS AND PLATFORMS

The app itself contacts exactly one address: the gateway address the user
types in. It has no backend of ours.

- No analytics, advertising, attribution, crash reporting or tracking SDK.
- No payment processor.
- No AI provider is contacted by the app. Whether an AI service is used at
  all, and which one, is configured by the user on their own server. The app
  has no credentials for and no knowledge of any such service.
- Apple frameworks provide dictation, read-aloud, and optional read-only Apple
  Health access. Authorized health samples go to the user's gateway; requested
  summaries may reach its configured model provider.
- Open-source Flutter plugins provide secure storage, notifications, an
  on-device SQLite cache, image picking, sharing, and Apple Health access.

6. REGIONAL DIFFERENCES

There are none. The app functions identically in all regions, with the same
features and the same content everywhere. It is localized into English,
Arabic, German, Spanish, French, Japanese, Korean, Portuguese and Chinese.
Localization changes interface language only.

7. REGULATED INDUSTRY OR PROTECTED MATERIAL

Not applicable. Hermes Go is a network client for software the user runs
themselves. It operates in no regulated industry, provides no regulated
service, and contains no protected third party material. The name Hermes
refers to the open source Hermes agent this client connects to. The app is an
unofficial community built client, which is stated on its first screen, and it
is not presented as affiliated with any other party.

This information has also been added to the Notes field in App Review
Information.

Thank you,
Tom
<!-- END INFO REQUEST BLOCK -->

---

## BLOCK C: reply to Guideline 2.5.1 and 2.3.3, build 41

Attach a physical-device recording that follows the steps below, and replace
the bracketed App Store Connect screenshot confirmation before sending.

<!-- BEGIN HEALTHKIT SCREENSHOT REPLY BLOCK -->
Thank you for identifying both issues. I addressed them in build 41.

Guideline 2.5.1:
Hermes Go now clearly identifies its optional integration as "Apple Health"
directly on the initial connection screen, before sign-in, and again in
Settings. Tapping either entry explains that the feature works with the Apple
Health app, is off by default, reads only categories the user explicitly
authorizes, sends those samples only to the user's authenticated self-hosted
Hermes gateway, and never writes to the Apple Health app. A requested summary
may be processed by the model provider the gateway owner configured. The
implementation uses HealthKit and does not use CareKit.

The attached recording was captured on a physical iPhone. It shows:
1. Launching Hermes Go and tapping Apple Health on the first screen.
2. The complete Apple Health disclosure.
3. Entering the built-in sample workspace using demo.hermes.go / demo / demo.
4. Opening Settings, then Apple Health, where the disclosure and
   sync controls are clearly visible.

Guideline 2.3.3:
[I replaced the 13-inch iPad screenshots. The majority now show the actual app
in use, including a live chat, Bot Mode, jobs, and Settings. I removed
promotional images that did not depict the application UI.]

Thank you,
Tom
<!-- END HEALTHKIT SCREENSHOT REPLY BLOCK -->

### App Store description insertion for build 41

Add this under WHAT YOU CAN DO so the marketing text also identifies the
integration, as required by Guideline 2.5.1:

• On iPhone and iPad, optionally sync health data you authorize from the Apple
Health app to your authenticated, self-hosted gateway for bounded bot summaries.
The gateway may send a requested summary to its configured model provider.
Hermes Go reads only, never writes to the Apple Health app, and the feature is
off by default.

---

## BLOCK B: reply to the Guideline 2.1(a) message about a demo authentication code

Submission ID cef05d7f-02cd-4c0a-884d-abe10b3daebd, reviewed August 05 2026.
This is the message asking for an authentication code and offering a call.

<!-- BEGIN AUTHCODE REPLY BLOCK -->
Thank you for the review, and for setting out the options.

There is no authentication code for this app, and none exists to give you. I
can see why the previous build looked as though there was one, and I am sorry
for the wasted round trip.

Hermes Go is a client for a Hermes agent gateway that the user runs on their
own computer, in the same way an SSH client or a NAS app connects to a server
the user runs themselves. The first field on the connect screen asks for that
server's address, not for a code. The username and password are issued by the
user's own server. In build 5 we supplied credentials but no reachable server,
so there was nothing for the reviewer to sign in to and no way past the first
screen. That was our mistake.

We have taken the third option you recommended, "including a demonstration
mode that exhibits the app's full features and functionality". It is bundled
in the new build and needs no server, no code and no network access.

To sign in:
1. Launch the app.
2. On the connect screen, in "Gateway base URL", enter: demo.hermes.go
3. Tap Continue.
4. Username: demo
5. Password: demo
6. Tap Sign In.

That gives you a fully working sample workspace with existing chat history.
You can send messages and watch replies stream in with live tool calls, start
new chats, switch models, browse the slash command reference and the skills
catalog, and pause or resume scheduled jobs. A suggested tour is in the App
Review Information notes for this version.

The sample workspace runs entirely on the device, on 127.0.0.1, and no network
calls leave the device. It is available to every user, not only to reviewers:
the same host and credentials work for anyone, it is documented in the app
under Settings, then About, and the app performs no reviewer detection of any
kind. A "Sample" chip is shown while it is active so that its scripted replies
can never be mistaken for a real agent.

A call should not be necessary, since there is no code to convey. If anything
in the sample workspace does not behave as described, please tell me what you
saw and I will fix it promptly.

Thank you,
Tom
<!-- END AUTHCODE REPLY BLOCK -->

---

## BLOCK C: reply to the earlier VPN message

<!-- BEGIN REPLY BLOCK -->
Thank you for the review.

Regarding the VPN question, Hermes Go has no VPN functionality of any kind:

- It does not use NetworkExtension, NEVPNManager or NETunnelProvider.
- It requests no VPN entitlement and bundles no tunneling library. There is
  no WireGuard, no OpenVPN and no proprietary tunnel code.
- Its only network operations are ordinary HTTPS and HTTP requests plus a
  single WebSocket connection to a gateway address the user supplies, and
  standard local network access to reach that gateway on the user's own LAN,
  governed by NSLocalNetworkUsageDescription.

To answer the three specific questions: the app collects no user information
using VPN, because it has no VPN functionality. There is therefore no purpose
for which such data is collected, and no data is shared with any third party.
Chat messages travel directly between the user's device and the user's own
self-hosted gateway. We operate no server in that path.

We believe the automated analysis flagged the app because the word "VPN"
appears in user-facing text. Every occurrence is guidance about the user's own
network, never a feature we ship. The complete list:

1. NSLocalNetworkUsageDescription: "Hermes Go connects to your Hermes agent
   gateway on the local network or VPN."
2. Three connection status messages, shown when the user's own gateway is
   unreachable or is being reached over plain HTTP:
   "Auto-reconnect gave up. Tap Reconnect (or check VPN / host)."
   "Cannot reach the gateway. Check VPN/Tailscale and host power."
   "Unencrypted HTTP: fine on your own LAN or VPN, use HTTPS for anything
   public."
3. Our developer documentation, which recommends that a user who wants to
   reach their self-hosted gateway from outside their home network do so over
   a private network rather than a port forward.

All of these describe networking the user may already have configured,
typically Tailscale, a third party product that we do not bundle, link
against, install, configure or control. The app has no awareness of whether
such software is present. This is the same pattern as an SSH client or a NAS
app documenting that you can reach your own server over your own VPN if you
choose to.

Regarding demo access, we have added a sample workspace to the build so that
review can proceed without setting up a server. Full sign-in steps and a
suggested tour are in the App Review Information notes for this version.

Thank you,
Tom
<!-- END REPLY BLOCK -->
