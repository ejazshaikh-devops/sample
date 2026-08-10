# FINAL Runbook — user-service + frontend-service + real RDS on real EKS

Scope: 1 backend (user-service), 1 frontend (frontend-service, nginx modified to
proxy /api/ straight to user-service), 1 real RDS MariaDB (free-tier: db.t3.micro,
20GB, single-AZ). Reliability feature: Autoscaling (HPA) on the backend.

## BEFORE THE 90-MIN CLOCK: apply Terraform (takes ~15-20 min, EKS + RDS provision
in parallel since both only depend on the VPC)
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit db_password inside, keep rest
terraform init
terraform apply    # type yes, then WAIT - go prep your Jenkins/Docker setup while this runs
```
When done:
```bash
terraform output rds_endpoint
terraform output   # also grab account id / ECR repo URLs if not already known
aws eks update-kubeconfig --name abhi-ejaz-cluster --region eu-north-1
kubectl get nodes    # confirms cluster is reachable
```

## STEP 1: Apply namespace, secrets, configmap
Edit `k8s/01-secrets.yaml` first - replace DB_HOST's base64 value with your real RDS endpoint:
```bash
echo -n "<your-rds-endpoint-from-terraform-output>" | base64
# paste that value into k8s/01-secrets.yaml under DB_HOST
```
Then:
```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-configmap.yaml
```

## STEP 2: Build and push both images to Docker Hub
```bash
docker login   # uses your Docker Hub username/password or access token

# Backend
docker build -f services/user-service/Dockerfile -t YOUR_DOCKERHUB_USERNAME/user-service:latest .
docker push YOUR_DOCKERHUB_USERNAME/user-service:latest

# Frontend - use the MODIFIED nginx.conf (frontend-nginx/nginx.conf from this package),
# copy it over services/frontend/nginx.conf before building
cp frontend-nginx/nginx.conf services/frontend/nginx.conf
docker build -f services/frontend/Dockerfile -t YOUR_DOCKERHUB_USERNAME/frontend-service:latest services/frontend
docker push YOUR_DOCKERHUB_USERNAME/frontend-service:latest
```
Note: if your Docker Hub repos are PRIVATE, your EKS nodes need a pull secret to access them -
tell me and I'll add the `imagePullSecrets` config. If PUBLIC, no extra config needed.

## STEP 3: Update k8s/03-deployments.yaml image placeholders, then deploy
Replace `YOUR_DOCKERHUB_USERNAME` in `k8s/03-deployments.yaml` with your real Docker Hub
username (appears twice - backend image and frontend image).
```bash
kubectl apply -f k8s/03-deployments.yaml
kubectl apply -f k8s/04-hpa.yaml
kubectl get pods -n abhi-ejaz -w        # wait for both deployments 1/1 or 2/2 READY
kubectl get svc frontend-service -n abhi-ejaz -w   # wait for EXTERNAL-IP (~2-3 min)
curl http://<external-ip>/ping          # frontend health
curl http://<external-ip>/api/health    # proxied through to user-service
```

## STEP 4: Jenkins pipeline (build → push → GitOps deploy via ArgoCD)
One-time prerequisite — ArgoCD must already be installed on the cluster and the
`k8s/argocd-app.yaml` Application applied once:
```bash
kubectl apply -f k8s/argocd-app.yaml
```
Then the Jenkinsfile:
- Checkout
- SonarQube scan + quality gate
- Build + push `user-service` image to Docker Hub
- Build + push `frontend-service` image to Docker Hub (using the modified nginx.conf)
- sed-patch the two image lines in `k8s/03-deployments.yaml`, commit, push to `main`

ArgoCD then detects the commit and syncs automatically (`selfHeal: true` in
argocd-app.yaml) — no `kubectl set image` step needed, ArgoCD is now the only
thing that should be touching live deployments.

Run it once manually first to confirm it works end-to-end before recording.
Watch it land with:
```bash
kubectl get application abhi-ejaz-shop -n argocd -w
```

## STEP 5: Demonstrate autoscaling live (this IS your reliability section)
```bash
kubectl get hpa -n abhi-ejaz -w    # keep this open in one terminal, watch REPLICAS live

# In another terminal, generate load against user-service:
kubectl run load-gen --image=busybox --restart=Never -n abhi-ejaz -- \
  /bin/sh -c "while true; do wget -q -O- http://user-service:3004/health; done"
```
Watch the HPA terminal — CPU% climbs, once it crosses 65% you'll see REPLICAS go from 2
toward higher numbers over the next minute or two. Point at this happening live.
Clean up after: `kubectl delete pod load-gen -n abhi-ejaz`

**Talking points for "why autoscaling, what problem, what tradeoff":**
- Why: e-commerce traffic is spiky (sales, flash drops) - fixed replica count either
  wastes money at idle or falls over at peak.
- Problem it solves: automatically matches capacity to real-time demand without you
  manually watching dashboards and scaling by hand.
- Tradeoff: reacting takes time (not instant - metrics need a few scrape cycles to
  trigger scale-up), and aggressive thresholds can cause "flapping" - scaling up and
  down repeatedly if traffic is noisy right around the threshold.

## STEP 6: Failure demo — bad image tag (ImagePullBackOff), same reliable pattern as before
NOTE: argocd-app.yaml has `selfHeal: true` — ArgoCD will detect a manual `kubectl set
image` as drift from git and revert it (default sync interval ~3 min), which can undo
this demo mid-recording. Either:
(a) pause self-heal first: `kubectl patch application abhi-ejaz-shop -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`
    then re-apply `k8s/argocd-app.yaml` after the demo to restore it, or
(b) do the bad-tag change through git (edit `k8s/03-deployments.yaml`, commit, push)
    so ArgoCD applies the failure itself — slower, but consistent with the GitOps model
    you're demonstrating.
```bash
kubectl set image deployment/user-service user-service=YOUR_DOCKERHUB_USERNAME/user-service:doesnotexist -n abhi-ejaz
kubectl get pods -n abhi-ejaz                      # new pod ImagePullBackOff
kubectl describe pod <new-pod> -n abhi-ejaz         # Events show exact pull error
# old pods keep serving traffic the whole time - point this out, rolling update didn't kill working pods
kubectl set image deployment/user-service user-service=YOUR_DOCKERHUB_USERNAME/user-service:latest -n abhi-ejaz
kubectl rollout status deployment/user-service -n abhi-ejaz
```

## STEP 7 — CRITICAL: tear down after recording
```bash
cd terraform
terraform destroy   # type yes - removes EKS, RDS, VPC, NAT gateway, everything
```
Also delete the ECR repos if `terraform destroy` doesn't (check `aws ecr describe-repositories`).
NAT Gateway + RDS + EKS control plane all bill hourly even sitting idle - don't leave this
running overnight by accident. sts
