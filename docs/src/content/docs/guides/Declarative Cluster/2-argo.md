---
title: Argo CD
description: Ship for success
draft: true
---

![Rendering of the planned cluster hardware](../../../../assets/todo.png)

### TODO: still a WIP



### ArgoCD
TODO

ArgoCD documentation says:
> For Argo CD v1.9 and later, the initial password is available from a secret named argocd-initial-admin-secret.

```
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Might take a while for argo to initialize, so I stuck this in a loop until it's ready
```
while kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | grep -q '^Error'; do sleep 1; done; kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```


## app of apps & projects
