# Foco para iOS

Câmera Bayer RAW e laboratório de pesquisa em profundidade de campo. Estima o mapa com Depth Pro 2 Base no aparelho e exporta o JPEG no tamanho da foto. Inclui revelação com grão e halation em Metal.

Execute `python3 scripts/fetch-model.py` e abra `Foco.xcodeproj` no Xcode. O script verifica a revisão e a integridade dos pesos antes da compilação. Para gerar um IPA sem assinatura, execute `bash scripts/build.sh`. A instalação no iPhone exige provisionamento próprio.

Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement. O modelo oficial está sujeito à licença de pesquisa incluída neste repositório. [Modelo da Apple](https://huggingface.co/apple/DepthPro2-coreml) · [Licença](LICENCA-MODELO.txt)

