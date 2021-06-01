```mermaid
graph LR
    A[Create Table] --> B[Insert 300K Rows] --> C[Delete 1/3 rows] --> D[Update 1/3 rows] --> E[Select All]
    F[Drop & Recreate Table] --> G[Insert 30K rows]
    G --> C
```