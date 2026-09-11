package schema

import _ "embed"

// NamespaceV1 is the schema shared by the namespace collector and Portal.
//
//go:embed namespace-v1.sql
var NamespaceV1 string
