# iPhone shortcuts (optional)

> **You probably don't need these.** The Droprr iPhone app (see [apple/README.md](../apple/README.md)) sends from the share sheet and collects queued items on its own. These Shortcuts-only versions are for an iPhone without the app.

The "Send to PC" shortcut sends photos and files you share on the iPhone to the PC running Droprr. Start with the basic version below. Once it works, you can add [text and links](#optional-text-and-links). The ["Get from PC"](#get-from-pc-pick-up-items-sent-to-the-phone) shortcut collects items the PC queued for the phone.

## Before you start

1. Tailscale is installed and connected on both the iPhone and the PC.
2. Droprr is running on the PC, and the Windows Firewall rule from the README is in place.
3. Get the token: right-click Droprr's tray icon, choose **Settings…**, and click **Copy** next to the token.
4. Note the PC's address: its Tailscale name (for example `my-pc`) or its Tailscale IP, both shown in the Tailscale app.

In the steps below, replace `<pc>` with that name or IP, and `<token>` with the token.

**Check the connection first.** In Safari on the iPhone, open `http://<pc>:53318/ping`. You should immediately see `{"ok":false,"error":"unauthorized"}`. That error is expected, since Safari doesn't send the token; it shows the phone can reach Droprr. If the page times out, fix that before building the shortcut (see [Troubleshooting](#troubleshooting)).

## Basic shortcut: photos and files

Open **Shortcuts**, tap **+**, and name the shortcut **Send to PC**.

1. **Share Sheet:** tap the **ⓘ** (Details) button and turn on **Show in Share Sheet**. Then tap the **Receive** line at the top of the editor and choose **Images**, **Media**, **Files**, and **PDFs**.
2. **Address:** add a **URL** action (in Web; not a Text action). **Type** `http://<pc>:53318/send` by hand, including `:53318`. Don't paste it, because a pasted address can become Rich Text, which Shortcuts can't use as a URL.
3. **Loop:** add **Repeat with Each** and set it to **Shortcut Input**.
4. **Upload:** inside the loop, add **Get Contents of URL**:
   - **URL:** the **URL** from step 2. Make sure this field isn't blank.
   - Tap **Show More**. **Method:** POST.
   - **Headers:** add `Authorization` with the value `Bearer <token>`, with one space after `Bearer`. Type it, or paste with long-press > **Paste and Match Style**.
   - **Request Body:** **File**, set to **Repeat Item**.

   Alternatively, use **Request Body: Form** with a **File** field named `file` set to **Repeat Item**. That keeps the photo's original file name; with Request Body: File, the PC names it `Droprr <date time>`. If you want original names with Request Body: File, add a header `X-Droprr-Filename` set to **Repeat Item** > **Name** (tap Repeat Item and choose Name).
5. **Check the reply (recommended while testing):** still inside the loop, add **Show Result** with the **Contents of URL**. A successful send shows `{"ok":true,"received":1}`. Once it works, you can remove this action or replace it with **Show Notification**.

### Try it

In Photos, share a picture and pick **Send to PC**. It should land in `Downloads\Droprr` on the PC, and the PC should show a notification.

## Optional: text and links

To also send text and links, wrap the basic shortcut in an **If** that checks what was shared.

1. **Receive:** in the **Receive** line, also choose **Text**, **URLs**, **Safari web pages**, and **Rich Text**. Optionally set **If there's no input** to **Get Clipboard**, so running the shortcut from the home screen sends the clipboard.
2. **Find the type:** after the URL action, add **Get Type** (in Scripting) with input **Shortcut Input**.
3. **Links:** add **If**, tap the condition, and choose **Any are true**. Add **Type** *is* `URL` and **Type** *is* `Safari web page`. Inside it:
   1. Add **Get URLs from Input** with input **Shortcut Input**.
   2. Add **Get Contents of URL** with the same URL, method, and header as the basic shortcut, but with **Request Body:** JSON, with two Text fields: `type` = `url` and `content` = **URLs**.
4. **Text:** in **Otherwise**, add another **If** set to **Any are true**, with **Type** *is* `Text` and **Type** *is* `Rich Text`. Text you share from Notes, Mail, and many other apps arrives as Rich Text. Inside it:
   1. Add **Get Text from Input** with input **Shortcut Input**. This turns rich text into plain text.
   2. Add **Get Contents of URL** like step 3.2, but with `type` = `text` and `content` = **Text**.
5. **Files:** move the basic shortcut's **Repeat with Each** loop into the inner **Otherwise** branch.

On the PC, text and links are copied to the clipboard and saved in `Downloads\Droprr`.

## Get from PC: pick up items sent to the phone

The PC holds anything you send to your iPhone until this shortcut runs (for up to 7 days). Create a new shortcut named **Get from PC**. It doesn't need the Share Sheet.

Pick a name for your phone, such as `iPhone`, and always use the same one. The first time the shortcut runs, the PC adds a device with that name, and it appears in the PC's Send window.

1. **List:** add a **URL** action and type `http://<pc>:53318/inbox?for=iPhone` by hand. Add **Get Contents of URL** with that URL, Method **GET**, and the header `Authorization` = `Bearer <token>`.
2. **Items:** add **Get Dictionary Value**: get **Value** for `items` in **Contents of URL**.
3. **Loop:** add **Repeat with Each** over **Dictionary Value**. Inside the loop:
   1. Add **Get Dictionary Value** for `id` in **Repeat Item**, then **Set Variable** `Item ID` to it.
   2. Add **Get Dictionary Value** for `type` in **Repeat Item**.
   3. Add **If** **Dictionary Value** *is* `file`:
      - Add a **URL** action: type `http://<pc>:53318/inbox/` and then insert the **Item ID** variable.
      - Add **Get Contents of URL** with that URL, Method **GET**, and the same `Authorization` header.
      - Add **Save File** with **Contents of URL** (or **Save to Photo Album** if you mostly send photos).
   4. In **Otherwise**: add **Get Dictionary Value** for `content` in **Repeat Item**, then **Copy to Clipboard**. For links, you can use **Open URLs** instead.
   5. After **End If**, add a **URL** action with `http://<pc>:53318/inbox/` plus **Item ID**, then **Get Contents of URL** with Method **DELETE** and the same header. This tells the PC the item arrived, so it's removed from the queue.
4. **Done (optional):** after **End Repeat**, add **Show Notification** with the text `Got everything from PC`.

To get items without thinking about it, add a Personal Automation in the Shortcuts app (for example, when you arrive home or connect to a Wi-Fi network) that runs **Get from PC**.

## Troubleshooting

- **"The request timed out":** the phone can't reach Droprr. Usually the URL is missing the port: it must be `http://<pc>:53318/send`, not `http://<pc>`. Test with `http://<pc>:53318/ping` in Safari. If that times out too, check that Tailscale is on for both devices, that Droprr is running, and that the firewall rule exists.
- **"Sent" but nothing arrives on the PC:** Shortcuts doesn't treat an error reply as a failure, so a notification at the end appears either way. Add **Show Result** after **Get Contents of URL** to see Droprr's reply:
  - `"unauthorized"`: the token is wrong. Check for a missing space after `Bearer` or an extra character.
  - `"empty body"`: the request had no content. Check that **Request Body** is set to **Repeat Item**, not left empty.
  - A `.txt` file or text on the clipboard instead of your photo: a Form field was added as **Text** rather than **File**, so the shortcut sent the photo's name instead of the photo. Switch to **Request Body: File**.
- **"Get Contents of URL failed because Shortcuts couldn't convert from Rich Text to URL":** the address isn't a real URL. There are two common causes:
  - The address is in a **Text** action, or was pasted with formatting. Replace it with a **URL** action (Web > URL) and type the address by hand.
  - A **Get Contents of URL** action has a blank URL field, so Shortcuts used the shared item as the address. Set its URL to the **URL** action.
- **A link arrives as a file, or text arrives as a link:** iOS sometimes reports a type you don't expect. Add **Show Result** after **Get Type** to see the actual name, then add a matching condition.
- **Allow access prompt:** the first time the shortcut talks to your PC, iOS asks permission to connect. Choose **Always Allow**.
