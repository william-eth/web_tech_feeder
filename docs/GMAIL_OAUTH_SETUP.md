# Gmail OAuth 2.0 Setup Guide

This project uses Gmail API + OAuth 2.0 Refresh Token for sending email, without SMTP passwords.

## 1. Obtain Refresh Token

### 1.1 Create OAuth 2.0 Credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Create or select a project
3. **Credentials** → **Create Credentials** → **OAuth client ID**
4. Application type: **Web application** or **Desktop app**
5. If using Web: add to **Authorized redirect URIs**:
   ```
   https://developers.google.com/oauthplayground
   ```

### 1.2 Enable Gmail API

1. **APIs & Services** → **Library**
2. Search for **Gmail API** → **Enable**

### 1.3 Get Refresh Token via OAuth 2.0 Playground

1. Open [OAuth 2.0 Playground](https://developers.google.com/oauthplayground/)
2. Click the gear icon (top right) → check **Use your own OAuth credentials**
3. Enter your **OAuth Client ID** and **OAuth Client secret** (you must use your own credentials, otherwise you will get `unauthorized_client`)
4. Close the settings panel
5. Select **Gmail API v1** → `https://www.googleapis.com/auth/gmail.send`
6. Click **Authorize APIs**, sign in with the Gmail account you want to use for sending
7. Click **Exchange authorization code for tokens**
8. Copy the **Refresh token** to `GMAIL_REFRESH_TOKEN`

## 2. Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `unauthorized_client` | Playground using default credentials | Enter your own Client ID / Secret in Playground settings |
| `redirect_uri_mismatch` | Missing or incorrect redirect URI | Add `https://developers.google.com/oauthplayground` to OAuth client (must match exactly, `https`, no trailing slash) |
| `Recipient address required` | Fixed | Pass raw RFC 2822 string; do not double base64 encode; ensure `EMAIL_TO` is set |
| `invalidArgument` | `EMAIL_TO` empty or malformed | Check `.env` for valid `EMAIL_TO` |

## 3. Environment Variables

```dotenv
GMAIL_CLIENT_ID=xxxx.apps.googleusercontent.com
GMAIL_CLIENT_SECRET=xxxx
GMAIL_REFRESH_TOKEN=xxxx
EMAIL_FROM=your_email@gmail.com   # Must match OAuth-authorized account
EMAIL_TO=recipient@example.com   # Multiple: comma or semicolon separated
EMAIL_BCC=archive@example.com    # Optional BCC
```

## 4. Multiple Recipients

`EMAIL_TO` supports comma or semicolon separation; whitespace is trimmed automatically:

```dotenv
EMAIL_TO=user1@example.com, user2@example.com
```

## 5. BCC (Optional)

`EMAIL_BCC` is optional and supports comma or semicolon separation (same format as `EMAIL_TO`). Useful for archiving or backup copies.

```dotenv
EMAIL_BCC=archive@example.com, backup@example.com
```
