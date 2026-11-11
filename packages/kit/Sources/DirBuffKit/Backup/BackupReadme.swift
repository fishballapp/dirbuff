/// `README.txt` in `DirBuff Backup/`: what the folder is, and how to restore from it with DirBuff
/// gone. Its `restic` commands are run as written by `StockResticTests`, and are the ones the
/// site's `/restore` page shows (`restoreCommands.ts`, held equal by a test): change all three
/// together.
enum BackupReadme {
  static let text = """
    DirBuff Backup
    ==============

    This folder holds the backups DirBuff made of folders on your Macs. Each folder in it is one
    Mac's backup: a restic repository (https://restic.net) holding every version DirBuff kept.
    It opens with no password, unless you protected that Mac's backup with one in DirBuff's
    Settings: then it opens only with that password.


    Only DirBuff may write to it
    ----------------------------

    Reading the backup with other tools is fine. Writing to it is not: DirBuff sees only the
    files it made itself, so a lock, `restic unlock`, `restic repair` or `restic forget` run by
    another tool (restic through rclone, say) is invisible to DirBuff and breaks its picture of
    the backup. Read with `--no-lock`, as below, and leave repairs to DirBuff.


    Restoring with DirBuff
    ----------------------

    On any Mac: DirBuff > Settings > Backup > Restore from Google Drive..., sign in to this Google
    account, and pick a Mac, a folder and a date.


    Restoring without DirBuff
    -------------------------

    You need restic: on a Mac, `brew install restic`; anywhere else, see https://restic.net.

    1. In drive.google.com, download the folder of the Mac you want. Google zips it, in several
       parts when it's large: unzip every part into one folder, say ~/Backup.

    2. List what's in it:

         restic -r ~/Backup --insecure-no-password snapshots

       Each line is one folder at one time. Its path says where the folder was, and its tag
       (folder=...) names the folder's series.

    3. Restore one of them, by its ID:

         restic -r ~/Backup --insecure-no-password restore <ID> --target ~/Restored

       or a folder's newest:

         restic -r ~/Backup --insecure-no-password restore latest \\
           --tag folder=<...> --target ~/Restored

    If that Mac's backup has a password, leave out --insecure-no-password and type the password
    when restic asks for it.


    A backup too big to download
    ----------------------------

    Read it where it is through rclone (https://rclone.org), with a remote set up for this Google
    account, say gdrive:. Always add --no-lock, so restic only reads and writes nothing:

      restic -r rclone:gdrive:"DirBuff Backup/<Mac>" --no-lock --insecure-no-password snapshots
      restic -r rclone:gdrive:"DirBuff Backup/<Mac>" --no-lock --insecure-no-password \\
        restore <ID> --target ~/Restored

    With a password, leave out --insecure-no-password again. If you moved or renamed this folder
    in Drive, use its new path.
    """
}
