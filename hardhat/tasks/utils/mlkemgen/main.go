package main

import (
	"crypto/mlkem"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
)

type KeyPair struct {
	RaylsViewSecretKey string `json:"raylsViewSecretKey"`
	RaylsViewPublicKey string `json:"raylsViewPublicKey"`
}

func main() {
	dk, ek, err := GenerateRaylsViewKeys()
	if err != nil {
		fmt.Println("Error generating Rayls View keys:", err)
		return
	}
	secretKey := hex.EncodeToString(dk.Bytes())
	publicKey := hex.EncodeToString(ek.Bytes())

	keyPair := KeyPair{
		RaylsViewSecretKey: secretKey,
		RaylsViewPublicKey: publicKey,
	}

	fileData, err := json.MarshalIndent(keyPair, "", "    ")
	if err != nil {
		fmt.Println("Error marshaling JSON:", err)
		return
	}

	file, err := os.Create("keypair.json")
	if err != nil {
		fmt.Println("Error creating file:", err)
		return
	}
	defer file.Close()

	_, err = file.Write(fileData)
	if err != nil {
		fmt.Println("Error writing to file:", err)
		return
	}
}

func GenerateRaylsViewKeys() (*mlkem.DecapsulationKey768, *mlkem.EncapsulationKey768, error) {
	dk, err := mlkem.GenerateKey768()

	if err != nil {
		return nil, nil, err
	}

	ek := dk.EncapsulationKey()

	return dk, ek, nil
}
