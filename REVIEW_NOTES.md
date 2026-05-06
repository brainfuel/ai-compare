# App Store Review Notes — AI Compare

Paste the contents below into **App Store Connect → App Review Information → Notes** for each submission. Update the "Devices Tested" section with the actual hardware/OS used for the build.

For Guideline 2.1 screen-recording requests, attach a 60–90s recording on a real device showing: launch → entering an API key → loading models → sending a prompt → response → switching to Compare mode.

---

```
APP PURPOSE & TARGET AUDIENCE (#3)
AI Compare is a "bring your own API key" client that lets users send the same prompt to multiple
AI models (Gemini, OpenAI/ChatGPT, Anthropic/Claude, xAI/Grok) and compare their responses
side by side. Target audience: developers, researchers, and prompt engineers who already hold
API keys with these providers and want to evaluate model quality, tone, and accuracy.

There is no account system, no in-app purchase, no subscription, and no user-generated content
shared between users. All API keys are stored locally in the device Keychain.

SETUP / HOW TO TEST (#4)
AI Compare is a "bring your own API key" (BYOK) client. There is no shared backend
or account system — each user supplies their own API key from one of the supported
AI providers. We are unable to share a personal key for review.

The fastest free option for review is Google's Gemini API, which offers a free tier
with no credit card required:

1. Go to https://aistudio.google.com/apikey
2. Sign in with any Google account.
3. Click "Create API key" → copy the key.

Then in AI Compare:
1. Launch the app — it opens in "Single" mode.
2. In the Connection section, leave provider set to "Gemini".
3. Paste the key into the "Gemini API Key" field.
4. Tap "Load Models" → pick e.g. "gemini-2.5-flash".
5. Type any prompt (e.g. "Hello, what model are you?") and tap Send.
6. Switch to the "Compare" tab to send the same prompt to multiple providers
   simultaneously (additional keys required for those providers — OpenAI, Anthropic,
   and xAI also offer free credits for new accounts).

The app stores all keys locally in the device Keychain. No keys are transmitted
anywhere except directly to the relevant provider's HTTPS API.

EXTERNAL SERVICES (#5)
The app communicates only with the following first-party AI provider HTTPS APIs,
using the user's own API key:
- Google Gemini API (generativelanguage.googleapis.com)
- OpenAI API (api.openai.com)
- Anthropic API (api.anthropic.com)
- xAI Grok API (api.x.ai)
No analytics, telemetry, ad networks, or third-party SDKs are used.

REGIONAL DIFFERENCES (#6)
The app behaves identically in all regions. Availability of individual AI providers depends on
each provider's own regional restrictions, not the app.

REGULATED INDUSTRY / PROTECTED MATERIAL (#7)
Not applicable. The app does not operate in a regulated industry and does not bundle any
protected third-party material — all model responses are generated live by the user's own
provider account.

DEVICES TESTED (#2)
- [iPad model], iPadOS [version]
- [Mac model], macOS [version]
- [Apple Vision Pro if applicable], visionOS [version]

PURPOSE STRINGS (Guideline 5.1.1)
NSPhotoLibraryUsageDescription: used only when the user taps the camera/photo picker button
in the composer to attach an image to their AI prompt. The image is sent to the user's chosen
AI provider as part of the conversation; it is not uploaded anywhere else.
```
