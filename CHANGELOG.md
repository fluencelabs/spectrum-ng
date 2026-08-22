# Changelog

## [0.2.3](https://github.com/fluencelabs/spectrum-ng/compare/v0.2.2...v0.2.3) (2026-08-22)


### Features

* **kube-ovn:** add OVN_TUNNEL_IFACE and SERVICE_CIDR, apply chart CRDs on upgrade ([#199](https://github.com/fluencelabs/spectrum-ng/issues/199)) ([0ccfc6c](https://github.com/fluencelabs/spectrum-ng/commit/0ccfc6cc18860b4a8973fc88c11262c98fd2095e))
* **observability:** alert when a VPC cannot attach to the egress fabric ([#217](https://github.com/fluencelabs/spectrum-ng/issues/217)) ([c110a4a](https://github.com/fluencelabs/spectrum-ng/commit/c110a4aef52e0353316d5379a1bb8e6cc090a169))
* **observability:** alert when tenant VMs cannot resolve DNS ([#218](https://github.com/fluencelabs/spectrum-ng/issues/218)) ([9e5ba85](https://github.com/fluencelabs/spectrum-ng/commit/9e5ba856a05a1772670c3e5316a8e2ea39c562d8))
* **observability:** alert when the OIDC layer is down or a mesh workload lost its NetBird sidecar ([#213](https://github.com/fluencelabs/spectrum-ng/issues/213)) ([9b7dddb](https://github.com/fluencelabs/spectrum-ng/commit/9b7dddb5c8aeb25e26adfbe5c98264b67e701449))
* **storage:** remove linstor Subnet and NAD from flux overlays ([#202](https://github.com/fluencelabs/spectrum-ng/issues/202)) ([40e16eb](https://github.com/fluencelabs/spectrum-ng/commit/40e16ebb1618f5a2e0dd84bb0b0a1b2569dd4be8))
* **storage:** scrape drbd-reactor and alert on DRBD quorum and connection loss ([#207](https://github.com/fluencelabs/spectrum-ng/issues/207)) ([c13f87c](https://github.com/fluencelabs/spectrum-ng/commit/c13f87c77ff6aa2c0f29d573d8730001333b699b))


### Bug Fixes

* **cdi:** pin the importer back to 1.64.0 — 1.65/1.66 cannot write 4K block devices ([#227](https://github.com/fluencelabs/spectrum-ng/issues/227)) ([bdd2309](https://github.com/fluencelabs/spectrum-ng/commit/bdd2309081f8c53f5c1803571d02ca84be51f557))
* **flux:** pair the operator's hostNetwork with a Recreate strategy ([#201](https://github.com/fluencelabs/spectrum-ng/issues/201)) ([f4ccbfe](https://github.com/fluencelabs/spectrum-ng/commit/f4ccbfec00fd7f5492f37b7ef0c1b082011ea7c6))
* **ingress:** pin the Envoy LoadBalancer external address ([#196](https://github.com/fluencelabs/spectrum-ng/issues/196)) ([d9bc726](https://github.com/fluencelabs/spectrum-ng/commit/d9bc726b2e1da72f5f313f340e710867b00c3dfe))
* **kube-ovn:** stop InconsistentPortBindings firing on completed setup Jobs ([#228](https://github.com/fluencelabs/spectrum-ng/issues/228)) ([0e89dd3](https://github.com/fluencelabs/spectrum-ng/commit/0e89dd3e41e1f6e79c7cb9c758ccc9e550cbda6c))
* **kubevirt:** CDI 1.65.0 -&gt; 1.66.0 to fix imports into 4k block devices ([#226](https://github.com/fluencelabs/spectrum-ng/issues/226)) ([5c5fd88](https://github.com/fluencelabs/spectrum-ng/commit/5c5fd88714d5cf625a745ccfca328e9b87972abe))
* **netbird:** make missed sidecar injection impossible instead of silent ([#229](https://github.com/fluencelabs/spectrum-ng/issues/229)) ([bd2b863](https://github.com/fluencelabs/spectrum-ng/commit/bd2b863058b2259dbea746304bbd0b58664bf4d2))
* **netbird:** scope PAT rotation to the cluster's own tokens, and stop leaking the PAT into an annotation ([#224](https://github.com/fluencelabs/spectrum-ng/issues/224)) ([f372eec](https://github.com/fluencelabs/spectrum-ng/commit/f372eec421c25384444508495693c6a39d302bf2))
* **netbird:** strip the leaked PAT annotation on every run, not only when rotating ([#225](https://github.com/fluencelabs/spectrum-ng/issues/225)) ([ae9d44c](https://github.com/fluencelabs/spectrum-ng/commit/ae9d44c244c9939ffa82b8e0e04c2063b2bb7f36))
* **observability:** put the crd-operator vlogs filters in expr — they were alerting on INFO logs ([#216](https://github.com/fluencelabs/spectrum-ng/issues/216)) ([a0012c3](https://github.com/fluencelabs/spectrum-ng/commit/a0012c3365e9e6a899f560e76f378bbb0d81db1c))
* **observability:** put the OIDC vlogs filter in expr — params.query is never applied ([#215](https://github.com/fluencelabs/spectrum-ng/issues/215)) ([89dceb8](https://github.com/fluencelabs/spectrum-ng/commit/89dceb8d47f9f622934bf510549888a4e993cea3))
* **observability:** restore cluster-wide rule discovery for both vmalert instances ([#210](https://github.com/fluencelabs/spectrum-ng/issues/210)) ([b20a7e6](https://github.com/fluencelabs/spectrum-ng/commit/b20a7e6462ab01c2047203fc8a1bf38dc6283042))
* **observability:** scope the OIDC vlogs alert to a time window so it stops firing on old logs ([#214](https://github.com/fluencelabs/spectrum-ng/issues/214)) ([0fc63ea](https://github.com/fluencelabs/spectrum-ng/commit/0fc63ea37caaa961bd3e53526dc68ea97a1f8ae1))
* **observability:** split PromQL readiness rules out of the vlogs-labelled VMRule ([#211](https://github.com/fluencelabs/spectrum-ng/issues/211)) ([61f0621](https://github.com/fluencelabs/spectrum-ng/commit/61f06211dc523b713ddda247d37d35cd1e10a1d3))
* **observability:** stop the metrics vmalert from evaluating vlogs rules ([#209](https://github.com/fluencelabs/spectrum-ng/issues/209)) ([1db93ce](https://github.com/fluencelabs/spectrum-ng/commit/1db93ced90906bde38732ac6cfe52446e662b2d8))
* **storage:** scrape drbd-reactor through a Service so the DRBD alerts get data ([#208](https://github.com/fluencelabs/spectrum-ng/issues/208)) ([f3d4b4b](https://github.com/fluencelabs/spectrum-ng/commit/f3d4b4b9f7e6b3d97772a6bc52d28e3b188c53a4))

## [0.2.2](https://github.com/fluencelabs/spectrum-ng/compare/v0.2.1...v0.2.2) (2026-07-31)


### Features

* **storage:** point DRBD replication at the storage network on mainnet ([#190](https://github.com/fluencelabs/spectrum-ng/issues/190)) ([d35f16b](https://github.com/fluencelabs/spectrum-ng/commit/d35f16be134616c9f8dae8869028781d53779bbf))


### Bug Fixes

* **flux:** declare spec.kustomize on the GitOps FluxInstance to match bootstrap ([#189](https://github.com/fluencelabs/spectrum-ng/issues/189)) ([c67c8fa](https://github.com/fluencelabs/spectrum-ng/commit/c67c8fa3047a2603a0e11a5dc623eaaa6e03a11a))

## [0.2.1](https://github.com/fluencelabs/spectrum-ng/compare/v0.2.0...v0.2.1) (2026-07-31)


### Features

* **storage:** attach LINSTOR satellites to the storage network on mainnet and testnet ([#185](https://github.com/fluencelabs/spectrum-ng/issues/185)) ([ec3e3e2](https://github.com/fluencelabs/spectrum-ng/commit/ec3e3e28c0c266440178e8ce39ebdf0a9b000cb8))
* **storage:** point DRBD replication at the storage network on testnet ([#188](https://github.com/fluencelabs/spectrum-ng/issues/188)) ([84c9d50](https://github.com/fluencelabs/spectrum-ng/commit/84c9d5095300fee3f6b6b23b608d7cd7c97cecc3))
* **storage:** set the LINSTOR subnet MTU on mainnet and testnet ([#187](https://github.com/fluencelabs/spectrum-ng/issues/187)) ([4c9ec12](https://github.com/fluencelabs/spectrum-ng/commit/4c9ec128bf0383863e41752c3e3aabd90e44ab56))


### Bug Fixes

* **flux:** make the artifact store reachable across nodes, not just on source-controller's own ([#183](https://github.com/fluencelabs/spectrum-ng/issues/183)) ([148098f](https://github.com/fluencelabs/spectrum-ng/commit/148098f13ffc8a14926829754a16238bdbd91e4a))
* **observability:** ProviderNetworkNodeNotReady never fires — missing kube_customresource_ prefix ([#184](https://github.com/fluencelabs/spectrum-ng/issues/184)) ([fb3b772](https://github.com/fluencelabs/spectrum-ng/commit/fb3b772117cadb6c6335b0cd666767765a32c439))

## [0.2.0](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.10...v0.2.0) (2026-07-30)


### ⚠ BREAKING CHANGES

* Migrate to crd operator ([#105](https://github.com/fluencelabs/spectrum-ng/issues/105))

### Features

* add crd readiness metrics/alets ([#134](https://github.com/fluencelabs/spectrum-ng/issues/134)) ([9572986](https://github.com/fluencelabs/spectrum-ng/commit/9572986b0e6d48472485172ddb375e8b50e97e47))
* add netbird operator stack for cluster mesh networking ([#128](https://github.com/fluencelabs/spectrum-ng/issues/128)) ([9d7e34a](https://github.com/fluencelabs/spectrum-ng/commit/9d7e34a8976daa465d5f61ed411921539c871831))
* **crd-operator:** upgrade to 2026-06-16 release + expose vm-api via gateway ([#136](https://github.com/fluencelabs/spectrum-ng/issues/136)) ([d36039a](https://github.com/fluencelabs/spectrum-ng/commit/d36039ac9c1e24e1d859aad75b660c85a1bfd856))
* **egress:** parameterize external-VPC egress per cluster ([#158](https://github.com/fluencelabs/spectrum-ng/issues/158)) ([606593b](https://github.com/fluencelabs/spectrum-ng/commit/606593b167e8951e47fee420fe5cf1716e64645f))
* Grafana OIDC login via Authentik ([#140](https://github.com/fluencelabs/spectrum-ng/issues/140)) ([b33e8bd](https://github.com/fluencelabs/spectrum-ng/commit/b33e8bd79cab01e21d4dcc8c96fec69c4d35c50a))
* Grafana OIDC token/userinfo over mesh-only authentik.infra ([#142](https://github.com/fluencelabs/spectrum-ng/issues/142)) ([5dbc165](https://github.com/fluencelabs/spectrum-ng/commit/5dbc16533dadbdc372f55c4bfe835e05bdf70aa3))
* **ingress:** read CLOUDFLARE_TOKEN from the Secret, not the ConfigMap ([#176](https://github.com/fluencelabs/spectrum-ng/issues/176)) ([de04bfe](https://github.com/fluencelabs/spectrum-ng/commit/de04bfeca24846394a0a81bfeeea231e311036bc))
* **ingress:** set resources for external-dns-cloudflare ([#169](https://github.com/fluencelabs/spectrum-ng/issues/169)) ([58e2fe9](https://github.com/fluencelabs/spectrum-ng/commit/58e2fe94c45599ecc56a93d285a1a63d37eda54d))
* kube-oidc-proxy — OIDC kubectl access to beam over mesh (Authentik) ([#145](https://github.com/fluencelabs/spectrum-ng/issues/145)) ([4510dab](https://github.com/fluencelabs/spectrum-ng/commit/4510dab2d81bc34fdf273fcfb4c789d017f26faf))
* **kubevirt:** enable VolumesUpdateStrategy + VolumeMigration gates ([#141](https://github.com/fluencelabs/spectrum-ng/issues/141)) ([131c583](https://github.com/fluencelabs/spectrum-ng/commit/131c583032d768532158393731cca10860424c68))
* Migrate to crd operator ([#105](https://github.com/fluencelabs/spectrum-ng/issues/105)) ([774d17a](https://github.com/fluencelabs/spectrum-ng/commit/774d17a7efa12437f23a8a87de7e0ee9a01e4704))
* **netbird:** upgrade operator to v0.6.0 (OCI chart) + inline routing-peer CR ([#146](https://github.com/fluencelabs/spectrum-ng/issues/146)) ([4bda518](https://github.com/fluencelabs/spectrum-ng/commit/4bda51808cb10ad19bed93623eefcc9319f33c1e))
* **networking:** deploy NetBird on testnet and mainnet so Grafana mesh OIDC works on all clusters ([#144](https://github.com/fluencelabs/spectrum-ng/issues/144)) ([bdce6ce](https://github.com/fluencelabs/spectrum-ng/commit/bdce6ce0e703744c828d8ae3753580d832674879))
* **observability:** alert when a ProviderNetwork is not ready on a node ([#179](https://github.com/fluencelabs/spectrum-ng/issues/179)) ([5c0f9ad](https://github.com/fluencelabs/spectrum-ng/commit/5c0f9ad1443ee3aeb92c012871aadc1772c822b1))
* remove kubevirt VMI alerts ([#138](https://github.com/fluencelabs/spectrum-ng/issues/138)) ([8475683](https://github.com/fluencelabs/spectrum-ng/commit/84756831b23bd4b2e68c10363c651d3594aec8df))
* **storage:** declare PrefNic for the stage LINSTOR satellite ([#172](https://github.com/fluencelabs/spectrum-ng/issues/172)) ([85076e7](https://github.com/fluencelabs/spectrum-ng/commit/85076e763f65853ffd0459c69d9e63d4ac584556))
* **storage:** dedicated LINSTOR network on stage, parameterize its CIDR ([#168](https://github.com/fluencelabs/spectrum-ng/issues/168)) ([65988bf](https://github.com/fluencelabs/spectrum-ng/commit/65988bff2524a4aa61af374d51242e95fc1bd535))
* **storage:** set the LINSTOR subnet MTU from STORAGE_MTU ([#174](https://github.com/fluencelabs/spectrum-ng/issues/174)) ([7425a56](https://github.com/fluencelabs/spectrum-ng/commit/7425a56d68823d24ec39f3b56a95435573160d14))


### Bug Fixes

* add grafana http router ([9553003](https://github.com/fluencelabs/spectrum-ng/commit/955300360fc84f0a0844d78f59555e531250d682))
* add grafana http router ([#114](https://github.com/fluencelabs/spectrum-ng/issues/114)) ([48785ca](https://github.com/fluencelabs/spectrum-ng/commit/48785ca65deb43ce162f7a1cca0e53da822e0050))
* add observability on stage ([#113](https://github.com/fluencelabs/spectrum-ng/issues/113)) ([b2a364c](https://github.com/fluencelabs/spectrum-ng/commit/b2a364c840b648b8386f24f7fb5ca9b186d31fb7))
* added a crd alerts ([#111](https://github.com/fluencelabs/spectrum-ng/issues/111)) ([482a69d](https://github.com/fluencelabs/spectrum-ng/commit/482a69da07cd8d419591e8878e722a6cf316edaf))
* crd condition metrics corrections ([#137](https://github.com/fluencelabs/spectrum-ng/issues/137)) ([927d997](https://github.com/fluencelabs/spectrum-ng/commit/927d9972e89e2c0665816a7f5f94275852021ad7))
* crd rules ([ee03233](https://github.com/fluencelabs/spectrum-ng/commit/ee03233d14176f72a477208e7b8b817f27dae5e3))
* crd rules logql ([#119](https://github.com/fluencelabs/spectrum-ng/issues/119)) ([ee03233](https://github.com/fluencelabs/spectrum-ng/commit/ee03233d14176f72a477208e7b8b817f27dae5e3))
* **crd:** update crd on mainnet ([#109](https://github.com/fluencelabs/spectrum-ng/issues/109)) ([adb8acb](https://github.com/fluencelabs/spectrum-ng/commit/adb8acb9e7e203f38aed54d771806715cf62dd56))
* **egress:** drop variables the controller has no fields for, rewrite the doc to the hub form ([#180](https://github.com/fluencelabs/spectrum-ng/issues/180)) ([432c4eb](https://github.com/fluencelabs/spectrum-ng/commit/432c4eb57c604c61d97d9a4f62c333245909f9a4))
* Fix flux observability ([#104](https://github.com/fluencelabs/spectrum-ng/issues/104)) ([9db5a2e](https://github.com/fluencelabs/spectrum-ng/commit/9db5a2e33c2749114c171954dec6331945382667))
* **flux:** escape shell vars from postBuild envsubst ([#167](https://github.com/fluencelabs/spectrum-ng/issues/167)) ([ac7cc11](https://github.com/fluencelabs/spectrum-ng/commit/ac7cc1129589db2dca7d78223fdd4a6683b95f84))
* **grafana:** source mesh root CA for tls_client_ca from fluence-mesh-intermediate secret ([#143](https://github.com/fluencelabs/spectrum-ng/issues/143)) ([2ce385a](https://github.com/fluencelabs/spectrum-ng/commit/2ce385aa774904dbb96ce1c7511d2456232d85e7))
* improved vm paused alerts ([#125](https://github.com/fluencelabs/spectrum-ng/issues/125)) ([8d3d4b2](https://github.com/fluencelabs/spectrum-ng/commit/8d3d4b245bbdeee0b8ef45d2965ae8b1243ba3cf))
* **lightmare:** update ([#107](https://github.com/fluencelabs/spectrum-ng/issues/107)) ([80302fb](https://github.com/fluencelabs/spectrum-ng/commit/80302fb808e8194fd073e6dc69d4edd3a8019c6a))
* **netbird:** add tcpPorts 443 to spectrum NBResources so access policy is created (operator v0.6.0) ([#147](https://github.com/fluencelabs/spectrum-ng/issues/147)) ([b445acf](https://github.com/fluencelabs/spectrum-ng/commit/b445acfcdec3b05a86f6fda10fd633d88de04040))
* **netbird:** dns flow ([#135](https://github.com/fluencelabs/spectrum-ng/issues/135)) ([725c753](https://github.com/fluencelabs/spectrum-ng/commit/725c753e549df61a5e8a973d24eb01c1579422bd))
* **netbird:** widen the PAT rotation window and stop misreporting a dead token ([#177](https://github.com/fluencelabs/spectrum-ng/issues/177)) ([ca3b24a](https://github.com/fluencelabs/spectrum-ng/commit/ca3b24a5e21bf2188e282671f771afc742a230ff))
* **observability:** bump node-exporter memory limit 64M → 256M (OOMKill on mainnet) ([#148](https://github.com/fluencelabs/spectrum-ng/issues/148)) ([9f9eedf](https://github.com/fluencelabs/spectrum-ng/commit/9f9eedfd2dd52bb525a47e350ebe13e9be4aeb19))
* **observability:** resolve kube-ovn dashboard datasource references ([#150](https://github.com/fluencelabs/spectrum-ng/issues/150)) ([9d50fbc](https://github.com/fluencelabs/spectrum-ng/commit/9d50fbc0cc801135734b03f29b29f4a5b00af662))
* **storage:** read spectrum-manual-vars in the linstor-cluster app ([#171](https://github.com/fluencelabs/spectrum-ng/issues/171)) ([bc3f35e](https://github.com/fluencelabs/spectrum-ng/commit/bc3f35e8c94e71312a85b88bb045ea567f60105d))
* switch crd-operator docker registry ([#156](https://github.com/fluencelabs/spectrum-ng/issues/156)) ([74931b0](https://github.com/fluencelabs/spectrum-ng/commit/74931b0b084a2f993b15b72a040cbf9a3b79d9fb))
* update crd on testnet ([#112](https://github.com/fluencelabs/spectrum-ng/issues/112)) ([259c41e](https://github.com/fluencelabs/spectrum-ng/commit/259c41eee8534f2132afc957d51de84bcb078ff9))
* update lightmare ([#127](https://github.com/fluencelabs/spectrum-ng/issues/127)) ([ca0329c](https://github.com/fluencelabs/spectrum-ng/commit/ca0329c7a9f0b5525645eacb706f52578dcbe6c6))
* update lightmare ([#130](https://github.com/fluencelabs/spectrum-ng/issues/130)) ([1a8d5ee](https://github.com/fluencelabs/spectrum-ng/commit/1a8d5ee827831b7f0d2256d5e152661e24de3161))
* update lightmare ([#132](https://github.com/fluencelabs/spectrum-ng/issues/132)) ([2a46bf2](https://github.com/fluencelabs/spectrum-ng/commit/2a46bf25da38d460784d264649c6ed74ab498dbf))

## [0.1.10](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.9...v0.1.10) (2026-03-24)


### Features

* Deploy ~stable version of crd-operator on testnet ([#85](https://github.com/fluencelabs/spectrum-ng/issues/85)) ([467609d](https://github.com/fluencelabs/spectrum-ng/commit/467609da74a38013a97c0b611f0cb6f081df92e6))
* Deploy crd-controller on stage and testnet ([#83](https://github.com/fluencelabs/spectrum-ng/issues/83)) ([84a47e9](https://github.com/fluencelabs/spectrum-ng/commit/84a47e987eb8de645b29405f5386f400aa460504))
* Update crd-operator on testnet ([#102](https://github.com/fluencelabs/spectrum-ng/issues/102)) ([a8c4a68](https://github.com/fluencelabs/spectrum-ng/commit/a8c4a68ffc3480f88d3603fb44089b9a17970a32))
* Update kube-ovn to 1.15.x ([#90](https://github.com/fluencelabs/spectrum-ng/issues/90)) ([5809253](https://github.com/fluencelabs/spectrum-ng/commit/58092539f95afcf2f1085815ba93ad178e2323db))


### Bug Fixes

* Bump cdi operator 1.63.0 -&gt; 1.64.0 ([#101](https://github.com/fluencelabs/spectrum-ng/issues/101)) ([79c5319](https://github.com/fluencelabs/spectrum-ng/commit/79c53196b1672fdaa08f0c3f0e20bd44925f7ecd))
* **lightmare:** fix overlay ([#79](https://github.com/fluencelabs/spectrum-ng/issues/79)) ([f1f76ac](https://github.com/fluencelabs/spectrum-ng/commit/f1f76acc637ee2650d48eddd799c2b7b95cb3def))
* **lightmare:** remove version override for stage and testnet ([#78](https://github.com/fluencelabs/spectrum-ng/issues/78)) ([4948f33](https://github.com/fluencelabs/spectrum-ng/commit/4948f33f7a8cbc1d5f16e1dbbcd8cfca408bb5e5))
* update lightmare to 0.7.17 ([#76](https://github.com/fluencelabs/spectrum-ng/issues/76)) ([2b3a55f](https://github.com/fluencelabs/spectrum-ng/commit/2b3a55f503b87d036f96836a5da99199e403064c))

## [0.1.9](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.8...v0.1.9) (2026-01-12)


### Features

* **lightmare:** test version ([#67](https://github.com/fluencelabs/spectrum-ng/issues/67)) ([f398387](https://github.com/fluencelabs/spectrum-ng/commit/f3983879bafa8a53a08af33575b754a23fac6233))


### Bug Fixes

* Disable ha controller and run satellites only on linstor ready nodes ([#72](https://github.com/fluencelabs/spectrum-ng/issues/72)) ([9453c86](https://github.com/fluencelabs/spectrum-ng/commit/9453c868e1b9024f676519b404903660df88f4fa))
* Dissallow remote access for single replica volumes ([#71](https://github.com/fluencelabs/spectrum-ng/issues/71)) ([c46f4e2](https://github.com/fluencelabs/spectrum-ng/commit/c46f4e281352a87a5552009ea16be46e06c83f7d))
* Dissallow remote volumes for replica 1 ([c46f4e2](https://github.com/fluencelabs/spectrum-ng/commit/c46f4e281352a87a5552009ea16be46e06c83f7d))
* **lightmare:** update ([#66](https://github.com/fluencelabs/spectrum-ng/issues/66)) ([275d079](https://github.com/fluencelabs/spectrum-ng/commit/275d0799cd8a44ce79ab2607753b245106ad130b))
* Linstor deployment as secondary storage class (not default) to mainnet ([#69](https://github.com/fluencelabs/spectrum-ng/issues/69)) ([a93b993](https://github.com/fluencelabs/spectrum-ng/commit/a93b9930f09c95f1a2875f7f7bfdd15d561596d0))

## [0.1.8](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.7...v0.1.8) (2025-11-25)


### Bug Fixes

* Linstor on testnet ([#58](https://github.com/fluencelabs/spectrum-ng/issues/58)) ([5c7915a](https://github.com/fluencelabs/spectrum-ng/commit/5c7915adf0d4449d31c17e3712603e79df7214f3))

## [0.1.7](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.6...v0.1.7) (2025-11-20)


### Bug Fixes

* update lightmare ([#56](https://github.com/fluencelabs/spectrum-ng/issues/56)) ([9e1946b](https://github.com/fluencelabs/spectrum-ng/commit/9e1946b30ef8a429c4e7f6529a84de214b58910a))

## [0.1.6](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.5...v0.1.6) (2025-11-14)


### Bug Fixes

* Use same env as in beam ([#50](https://github.com/fluencelabs/spectrum-ng/issues/50)) ([6dc1302](https://github.com/fluencelabs/spectrum-ng/commit/6dc130294a63db882aa3ad0e1867c4793653b876))

## [0.1.5](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.4...v0.1.5) (2025-10-29)


### Bug Fixes

* Run flux-operator only on control plane nodes ([#46](https://github.com/fluencelabs/spectrum-ng/issues/46)) ([605068d](https://github.com/fluencelabs/spectrum-ng/commit/605068df4296a165696e53af2c098ef00699f908))

## [0.1.4](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.3...v0.1.4) (2025-10-29)


### Bug Fixes

* Bump flux-operator version and fix first start issues ([#45](https://github.com/fluencelabs/spectrum-ng/issues/45)) ([e06752f](https://github.com/fluencelabs/spectrum-ng/commit/e06752ff3dc7b912d95418614f202cf35c2140a7))
* fix flux-operator monitoring label ([#41](https://github.com/fluencelabs/spectrum-ng/issues/41)) ([8d330f9](https://github.com/fluencelabs/spectrum-ng/commit/8d330f939df3efb50bdfee857357a737297ef418))

## [0.1.3](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.2...v0.1.3) (2025-10-21)


### Bug Fixes

* add kube-ovn alerts and labels cleanip ([#38](https://github.com/fluencelabs/spectrum-ng/issues/38)) ([210325e](https://github.com/fluencelabs/spectrum-ng/commit/210325e2783b3bd890944be7aab5a048f319a257))

## [0.1.2](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.1...v0.1.2) (2025-10-20)


### Bug Fixes

* disable proofs on mainnet ([#36](https://github.com/fluencelabs/spectrum-ng/issues/36)) ([51ce9aa](https://github.com/fluencelabs/spectrum-ng/commit/51ce9aa4bf91ab388d62c067357946df542f043e))

## [0.1.1](https://github.com/fluencelabs/spectrum-ng/compare/v0.1.0...v0.1.1) (2025-10-10)


### Features

* force no proofs ([#27](https://github.com/fluencelabs/spectrum-ng/issues/27)) ([7a4399e](https://github.com/fluencelabs/spectrum-ng/commit/7a4399e37c826a5de93cb6855b960790e1d55cca))
