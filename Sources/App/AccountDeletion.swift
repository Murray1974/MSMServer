// Static account-deletion request page served at GET /account-deletion, linked from the
// Google Play Console Data safety declaration for the student app (MSM Student).
let accountDeletionHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Delete Your Account — Murray School of Motoring</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.6; max-width: 700px; margin: 0 auto; padding: 24px 20px 60px; color: #1a1a1a; }
  h1 { font-size: 1.6em; margin-bottom: 0.2em; }
  h2 { font-size: 1.15em; margin-top: 1.8em; }
  p, li { font-size: 0.98em; }
  .updated { color: #666; font-size: 0.9em; margin-bottom: 2em; }
</style>
</head>
<body>
<h1>Delete Your Account</h1>
<p class="updated">Murray School of Motoring — MSM Student app<br>Last updated: 4 November 2026</p>

<p>If you'd like your MSM Student account and associated data deleted, email <a href="mailto:murray2007@icloud.com">murray2007@icloud.com</a> from the email address registered to your account, with the subject line "Delete my account".</p>

<h2>What to include</h2>
<ul>
  <li>The email address your account is registered under</li>
  <li>Confirmation that you want your account permanently deleted</li>
</ul>

<h2>What happens next</h2>
<p>We'll confirm your request and delete your account within 30 days.</p>

<h2>What gets deleted</h2>
<ul>
  <li>Your name, contact details, and login credentials</li>
  <li>Saved pickup/drop-off locations and provisional licence details</li>
  <li>Chat messages with your instructor</li>
  <li>Push notification device tokens</li>
</ul>

<h2>What may be kept</h2>
<p>Booking and payment records tied to completed lessons may be retained for a limited period afterwards where required for business accounting or legal obligations (e.g. financial record-keeping), even after your account is deleted. No new lessons can be booked once your account is deleted.</p>

<h2>Questions</h2>
<p>Contact <a href="mailto:murray2007@icloud.com">murray2007@icloud.com</a> with any questions about this process.</p>

</body>
</html>
"""
