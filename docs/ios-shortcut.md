# iPhone Share Sheet shortcut

This shortcut sends whatever you share (photos, files, text, or links) to the PC running Droprr. It also works from the home screen, where it sends the clipboard.

## Before you start

1. Tailscale is installed and connected on both the iPhone and the PC.
2. Droprr is running on the PC. Right-click the tray icon and choose **Copy token**, then get the token to your phone. Typing it is fine; it's in `%APPDATA%\Droprr\settings.json` too.
3. Note the PC's Tailscale name, as shown in the Tailscale app (for example `my-pc`). The address you'll use is `http://my-pc:53318/send`, with your own name and port.

In the steps below, replace `<pc-name>` and `<token>` with your values.

## Build the shortcut

Open **Shortcuts**, tap **+**, and name the shortcut **Send to PC**.

### 1. Set it up for the Share Sheet

1. Tap the **ⓘ** (Details) button and turn on **Show in Share Sheet**.
2. Back in the editor, tap the **Receive** line at the top. Choose **Images**, **Media**, **Files**, **Text**, **URLs**, **Safari web pages**, **PDFs**, and **Rich Text**.
3. Set **If there's no input** to **Get Clipboard**.

### 2. Store the address and token

1. Add a **URL** action (in Web, not a Text action). **Type** `http://<pc-name>:53318/send` by hand; don't paste it, because a pasted address can become Rich Text, which Shortcuts can't turn into a URL. Tap the action's output, choose **Rename**, and call it **Droprr URL**.
2. Add a **Text** action containing `Bearer <token>`, with one space after `Bearer`. Type it, or if you paste the token, long-press and use **Paste and Match Style** so it stays plain text. Rename its output to **Droprr Auth**.

### The request settings

Each **Get Contents of URL** action below uses the same settings:

- **URL:** **Droprr URL**. Make sure this field isn't blank. A blank URL field makes Shortcuts use the shared item as the address, which fails.
- **Method:** POST (tap **Show More**)
- **Headers:** add `Authorization` with the value **Droprr Auth**

### 3. Find out what was shared

1. Add **Get Type** (in Scripting) and set its input to **Shortcut Input**.
2. Add **If**, tap the condition, and choose **Any are true**. Add two conditions: **Type** *is* `URL` and **Type** *is* `Safari web page`.

### 4. Links: send JSON

Inside the first **If** branch:

1. Add **Get URLs from Input** with input **Shortcut Input**.
2. Add **Get Contents of URL** with the [request settings](#the-request-settings), and set:
   - **Request Body:** JSON, with two Text fields: `type` = `url` and `content` = **URLs** (from step 1)

### 5. Text: send JSON

1. In **Otherwise**, add another **If** set to **Any are true**, with **Type** *is* `Text` and **Type** *is* `Rich Text`. Text you share from Notes, Mail, and many other apps arrives as Rich Text.
2. Inside it, add **Get Text from Input** with input **Shortcut Input**. This turns rich text into plain text.
3. Add **Get Contents of URL** with the [request settings](#the-request-settings), and set:
   - **Request Body:** JSON, with two Text fields: `type` = `text` and `content` = **Text** (from step 2)

### 6. Everything else: send files

In the inner **Otherwise** branch:

1. Add **Repeat with Each** over **Shortcut Input**.
2. Inside the loop, add **Get Contents of URL** with the [request settings](#the-request-settings), and set:
   - **Request Body:** Form, with one **File** field named `file` whose value is **Repeat Item**

### 7. Confirm it worked (optional)

After the outer **End If**, add **Show Notification** with the text `Sent to PC`.

## Try it

1. In Photos, share a picture and pick **Send to PC**. It should land in `Downloads\Droprr` on the PC, and a notification should appear.
2. In Safari, share a page. The link should be on the PC's clipboard.
3. Copy some text and run the shortcut from the Shortcuts app. The text should be on the PC's clipboard.

## Troubleshooting

- **"Get Contents of URL failed because Shortcuts couldn't convert from Rich Text to URL":** the address isn't a real URL. There are two common causes:
  - The address is stored in a **Text** action, or was pasted with formatting. Replace that action with a **URL** action (Web > URL), type the address by hand, and rename its output to **Droprr URL** again.
  - A **Get Contents of URL** action has a blank URL field, so Shortcuts used the shared item as the address. Set each one's URL to **Droprr URL**.

- **"Could not connect to the server":** check that Tailscale is on for both devices, that Droprr is running, and that the Windows Firewall rule from the README exists.
- **401 Unauthorized:** the token is wrong. Check for a missing space after `Bearer` or an extra space at the end.
- **A link arrives as a file, or text arrives as a link:** iOS sometimes reports a type you don't expect, such as `Safari web page`. Add **Show Result** after **Get Type** to see the actual name, then add a matching **If** branch.
- **Allow access prompt:** the first time the shortcut talks to your PC, iOS asks permission to connect. Choose **Always Allow**.
