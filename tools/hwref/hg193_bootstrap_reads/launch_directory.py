"""Bind the mailbox's relative file dependency before starting a native ELF."""
import hashlib
from pathlib import Path

def check(binding):
 cwd=Path(binding['original_cwd']).resolve();mbox=cwd/'mbox.hex'
 assert mbox.is_file(),'native working directory has no mbox.hex'
 assert hashlib.sha256(mbox.read_bytes()).hexdigest()==binding['mbox_sha256'],'native mbox hash differs'
 assert binding['mbox_sha256']=='16a7d772c34b99b7195a823d31f39f9ea0e98597ee764ee2174e4ae532e85a91','wrong original HG mailbox'
 return cwd
