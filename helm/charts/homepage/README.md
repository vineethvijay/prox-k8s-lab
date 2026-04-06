# Homepage

Values override for the upstream [homepage](https://github.com/gethomepage/homepage) Helm chart.

```bash
helm repo add homepage https://gethomepage.github.io/homepage-helm
helm upgrade --install homepage homepage/homepage -n homepage -f helm/charts/homepage/values.yaml
```
