# Changelog — DirBuff

## 0.3.0

- Backup is the second buff. Give a folder Backup and its files go to your own Google Drive, every version kept. A folder backs up within an hour of a change; the card says when it last did, and DirBuff tells you when a backup needs you.
- DirBuff asks Google for one permission, to the files it creates in your Drive, and nothing else: it can't see anything else there. Nothing is backed up until you've confirmed the account. Your files go from your Mac to your Drive and nowhere else.
- History thins with age and never runs out: the latest 10 backups, then hourly for 2 days, daily for 30 days, weekly for 12 weeks, monthly for 2 years, and one a year after that. A folder can keep only a year or 30 days instead, which deletes the older versions from Drive.
- Browse Backup… on a Backup folder's card opens a backup like a folder in Finder's column view. Pick any backup kept, open folders, see what has changed or gone on your Mac since, and read a file's other versions. Preview a file with Quick Look (up to 100 MB), or drag it out to Finder.
- Restore puts a file or folder back where it was, under its own name, or beside it with the backup's date in the name when that name is taken. It never replaces anything. If the folder is gone, Restore To… asks where to put it. Restore Folder brings a whole backup back as a new folder beside the original.
- On a new Mac, or after losing a folder, Settings › Backup › Restore from Google Drive… brings back any of your Macs' backups. Keep Backing Up Here carries on in that backup, so nothing uploads twice.
- A backup has no password by default, so anyone who can open your Google account can read it. Settings › Backup › Protect with a Password… adds one, kept in your Keychain. On a Mac that doesn't have it, Browse Backup… asks for it. A lost password is a lost backup.
- Backup leaves out your Library when you back up your home folder, anything macOS tells Time Machine to skip, cache folders, `node_modules`, `.venv`, `.next`, `.turbo`, `.terraform`, `__pycache__` and `.DS_Store`, and files that are only in iCloud. The card lists what is left out, Leave Out adds a file, folder or name, and Bring Back undoes it.
- The Photos library isn't backed up yet.
- Files DirBuff couldn't read are listed under Show Files, each with why. Backups wait while the Mac is offline, on a hotspot or cellular connection or in Low Data Mode, in Low Power Mode, or on battery below 20%.
- Your backup can be read without DirBuff: a README in the Drive folder and dirbuff.fsh.ba/restore show how to get your files back with restic alone.

## 0.2.0

- DirBuff is rebuilt around buffs: a folder wears a buff, and Temporary is the first. Add one from the Buffs page, by dragging it onto a folder, or by right-clicking a folder in Finder and choosing DirBuff: Add Buff.
- The main window has a sidebar of All Folders, Buffs, History and each folder you've added. Each folder has its own page, showing what goes next, and a folder can wear no buffs at all.
- Finder tags are gone: a 💪 mark shows a buffed folder instead. The first launch takes the DirBuff: Temporary tag off your folders and leaves your other tags alone.
- Temporary now uses one rule per folder: Age, Size, Empty on restart or Automatic. A folder that used several keeps the first in that order, and the others' amounts are kept if you switch back.
- Choosing Automatic sets a folder to delete permanently, because moving files to the Bin frees no space.
- Desktop and Documents can now wear a buff. Your home folder, Library, system folders and the top of a disk stay protected.
- History lists every run, with Put Back from each run's page. A notification after each clean-up offers Put Back and Show.
- The menu-bar popover shows each clean-up as it runs.
- Updates confirm your licence before they download.
- A welcome window walks you through the first buff. It shows once after this update too.

## 0.1.5

- Buying a licence and managing it now happen in DirBuff's own Polar store, so checkout and the customer portal say DirBuff.
- DirBuff's icon no longer shows on drives in Finder's sidebar.
- Recent runs name the day of a run before today.

## 0.1.4

- Settings has an Updates section: the version you're running, a Check for Updates… button, and Get dev builds.
- Turn on Get dev builds to get every change as soon as it's merged. Some will be broken.

## 0.1.3

- DirBuff is now open source (GPL-3.0). After the 14-day trial, a licence is $10, £10 or €10 a year and supports its development; the monthly plan is gone.
- Stop whenever you like: if you cancel, you keep the last version released while you were paid up, and it keeps working. Only later versions need a renewal.
- DirBuff's update check offers a cancelled licence only the versions it covers, and says when a later one is waiting for a renewal.
- The buy buttons now read Support DirBuff…, or Renew DirBuff… once a licence has ended.

## 0.1.2

- Folders are cleared on the hour, every hour, and at no other time: not when DirBuff opens, when the Mac wakes, or when you leave a folder's settings. An hour the Mac sleeps through is skipped.
- The forecast counts down to each of today's clean-ups ("In 23 min"), to the second in the last minute.

## 0.1.1

- Finder's right-click item is now Add to DirBuff…, or Show in DirBuff on a folder you've added. Adding a folder no longer makes it Temporary: you switch that on in DirBuff's window.
- Enter Licence Key… sits under Buy DirBuff… in the menu bar and the main window.
- Your home folder, Desktop, Documents, Library, system folders and the top of a disk can no longer be added, and Finder doesn't offer them.

## 0.1.0

First release.

- Turn any folder into a Temporary folder from Finder's right-click menu.
- Four cleanup rules: Age (default 90 days), Size limit, Automatic (when disk space falls below 10%), and Empty on restart.
- Move to Bin (undoable, including Finder's Put Back) or Delete permanently per folder.
- Menu-bar window with a forecast of what goes next.
- 14-day trial, then a monthly or yearly licence key.
