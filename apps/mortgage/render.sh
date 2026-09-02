#!/usr/bin/env bash
# Regenerates deploy.yaml from index.html. Run after editing index.html, then
# commit both files. ArgoCD only reads deploy.yaml -- index.html is the source.
set -euo pipefail
cd "$(dirname "$0")"

{
cat <<'HEADER'
# Static mortgage calculator served by nginx at https://mortgage.tomb.local
#
# GENERATED FILE -- do not edit by hand. Edit index.html (and the templates in
# render.sh), then run ./render.sh and commit the result.
---
HEADER

kubectl create configmap mortgage-content \
  --from-file=index.html=index.html \
  --dry-run=client -o yaml

cat <<'MANIFESTS'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mortgage
  labels:
    app: mortgage
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mortgage
  template:
    metadata:
      labels:
        app: mortgage
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: http
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
              readOnly: true
            # nginx needs these writable; the root filesystem is read-only below.
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /var/run
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              # NET_BIND_SERVICE: bind port 80. CHOWN/SETUID/SETGID: the nginx
              # entrypoint chowns /var/cache/nginx and drops to the nginx user.
              add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
          readinessProbe:
            httpGet:
              path: /index.html
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /index.html
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
      volumes:
        - name: content
          configMap:
            name: mortgage-content
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mortgage
  labels:
    app: mortgage
spec:
  type: ClusterIP
  selector:
    app: mortgage
  ports:
    - name: http
      port: 80
      targetPort: http
---
# Server certificate issued by the in-cluster tomb-local-ca ClusterIssuer.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mortgage-tls
spec:
  secretName: mortgage-tls
  dnsNames:
    - mortgage.tomb.local
  issuerRef:
    name: tomb-local-ca
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mortgage
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
    traefik.ingress.kubernetes.io/router.middlewares: mortgage-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - mortgage.tomb.local
      secretName: mortgage-tls
  rules:
    - host: mortgage.tomb.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mortgage
                port:
                  name: http
MANIFESTS
} > deploy.yaml

echo "wrote $(pwd)/deploy.yaml"
