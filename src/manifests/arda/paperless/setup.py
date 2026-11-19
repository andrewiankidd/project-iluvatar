# What Paperless keeps in its database, not in its environment, set from
# Git and .env instead of by hand. Run by setup.yaml's CronJob, with
# Paperless's own image and data volume; safe to run any number of times.
#
#  1. Dex users are admins. A "Sign in with Dex" makes a plain Paperless user
#     on first use, which sees nobody's documents. Dex holds only the
#     household's logins, so each one is made a superuser.
#  2. Mail. With ARDA_PAPERLESS_MAIL_HOST, _USER and _PASSWORD set, the mail
#     account "inbox" and its rule "inbox": every PDF or image attached to a
#     mail in the folder (INBOX unless ARDA_PAPERLESS_MAIL_FOLDER) is
#     consumed, and the mail marked read. Without them, the rule is
#     switched off. Other accounts and rules, made in the web app, are left
#     alone; so are edits to the rule other than the ones set here.
import os
import sys

sys.path.insert(0, "/usr/src/paperless/src")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "paperless.settings")

import django  # noqa: E402

django.setup()

from allauth.socialaccount.models import SocialAccount  # noqa: E402
from django.contrib.auth.models import User  # noqa: E402
from paperless_mail.models import MailAccount, MailRule  # noqa: E402

# 1. Dex users.
for user in User.objects.filter(
    socialaccount__provider__in=["dex", "openid_connect"],
).distinct():
    if not (user.is_superuser and user.is_staff):
        user.is_superuser = True
        user.is_staff = True
        user.save(update_fields=["is_superuser", "is_staff"])
        print(f"{user.username}: now an admin (signed in with Dex)")

# 2. Mail.
host = os.environ.get("MAIL_HOST", "")
username = os.environ.get("MAIL_USER", "")
password = os.environ.get("MAIL_PASSWORD", "")
owner = User.objects.filter(username=os.environ.get("ADMIN_USER", "paperless")).first()

if host and username and password:
    account, _ = MailAccount.objects.update_or_create(
        name="inbox",
        defaults={
            "imap_server": host,
            "imap_port": int(os.environ.get("MAIL_PORT") or 993),
            # 993 is IMAP over TLS; anything else is STARTTLS.
            "imap_security": (
                MailAccount.ImapSecurity.SSL
                if int(os.environ.get("MAIL_PORT") or 993) == 993
                else MailAccount.ImapSecurity.STARTTLS
            ),
            "username": username,
            "password": password,
            "owner": owner,
        },
    )
    rule, created = MailRule.objects.update_or_create(
        name="inbox",
        defaults={
            "account": account,
            "folder": os.environ.get("MAIL_FOLDER") or "INBOX",
            "enabled": True,
            "owner": owner,
        },
    )
    if created:
        # Only on creation, so changes made in the web app stay.
        rule.action = MailRule.MailAction.MARK_READ
        rule.attachment_type = MailRule.AttachmentProcessing.ATTACHMENTS_ONLY
        rule.consumption_scope = MailRule.ConsumptionScope.ATTACHMENTS_ONLY
        rule.maximum_age = 30
        rule.save()
    print(f"mail: {username} at {host}, folder {rule.folder}")
else:
    updated = MailRule.objects.filter(name="inbox", enabled=True).update(enabled=False)
    print("mail: ARDA_PAPERLESS_MAIL_* not set" + (", rule switched off" if updated else ""))
