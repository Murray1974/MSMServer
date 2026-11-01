// Static privacy policy page served at GET /privacy-policy, linked from the App Store
// Connect and Google Play Console listings for the student app.
let privacyPolicyHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy — Murray School of Motoring</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; max-width: 700px; margin: 0 auto; padding: 24px 20px 60px; color: #1a1a1a; }
  h1 { font-size: 1.6em; margin-bottom: 0.2em; }
  h2 { font-size: 1.15em; margin-top: 1.8em; }
  p, li { font-size: 0.98em; }
  .updated { color: #666; font-size: 0.9em; margin-bottom: 2em; }
</style>
</head>
<body>
<h1>Privacy Policy</h1>
<p class="updated">Murray School of Motoring — Student App<br>Last updated: 1 November 2026</p>

<p>This policy explains what information the Murray School of Motoring student app collects, why, and how it's used. It applies to the student-facing mobile app only.</p>

<h2>Account &amp; booking information</h2>
<p>When you're set up as a student, we hold your name, contact details, and driving-licence details needed to run lessons and bookings — including lesson bookings, cancellations, and lesson history. This is used solely to operate the school: scheduling lessons, managing your account, and keeping records your instructor needs.</p>

<h2>Location</h2>
<p>The app asks for location access to let you set pickup and drop-off points for lessons, and to share live location during an active lesson so your instructor's tracking view works correctly. Location is only used for these purposes and isn't collected when you're not actively using these features.</p>

<h2>Photos &amp; documents</h2>
<p>The app lets you scan your provisional driving licence (to verify your details) and attach photos to messages sent to your instructor. These images are stored only as needed to support these features.</p>

<h2>Push notifications</h2>
<p>The app registers a device token with our server so we can send you notifications — for example, new lesson availability, chat messages, and lesson-tracking updates. This token identifies your device for the purpose of delivering notifications only.</p>

<h2>Payments</h2>
<p>Lesson payments are processed by Stripe. Card and payment details are handled directly by Stripe and are never stored on Murray School of Motoring's own servers.</p>

<h2>Face ID / biometric unlock</h2>
<p>If you enable the app's lock screen, Face ID (or your device passcode) is used to unlock the app. This is handled entirely by your device's own operating system — no biometric data is ever sent to or stored by Murray School of Motoring.</p>

<h2>Who can see your information</h2>
<p>Your information is visible to your driving instructor (Murray School of Motoring) for the purpose of running your lessons. It is not sold or shared with third parties for marketing purposes.</p>

<h2>Data retention</h2>
<p>We keep your account and booking records for as long as you're an active student, and for a reasonable period afterwards for business and legal record-keeping. You can ask us to delete your account and associated data at any time using the contact details below.</p>

<h2>Contact</h2>
<p>Questions about this policy, or requests to access or delete your data, can be sent to <a href="mailto:murray2007@icloud.com">murray2007@icloud.com</a>.</p>

</body>
</html>
"""
