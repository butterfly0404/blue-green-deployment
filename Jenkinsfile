
pipeline {
    agent any

    options {
        disableConcurrentBuilds()
    }

    environment {
        APP_NAME = 'blue-green-app'
        SERVICE_NAME = 'blue-green-service'
        SWITCHED = 'false'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Detect Active Environment') {
            steps {
                script {
                    def result = powershell(
                        returnStdout: true,
                        script: '''
                            $serviceJson = kubectl get service blue-green-service -o json --ignore-not-found 2>$null

                            if ($LASTEXITCODE -ne 0) {
                                throw "Could not query Kubernetes service"
                            }

                            if ([string]::IsNullOrWhiteSpace($serviceJson)) {
                                Write-Output "none"
                            } else {
                                $service = $serviceJson | ConvertFrom-Json
                                $color = $service.spec.selector.version

                                if (!$color) {
                                    throw "Service has no version selector"
                                }

                                Write-Output $color
                            }

                            $global:LASTEXITCODE = 0
                        '''
                    ).trim()

                    env.OLD_COLOR = result

                    if (result == 'none') {
                        env.NEW_COLOR = 'blue'
                    } else if (result == 'blue') {
                        env.NEW_COLOR = 'green'
                    } else if (result == 'green') {
                        env.NEW_COLOR = 'blue'
                    } else {
                        error "Unknown active environment: ${result}"
                    }

                    echo "Previous environment: ${env.OLD_COLOR}"
                    echo "Next environment: ${env.NEW_COLOR}"
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                powershell '''
                    $image = "blue-green-app:$env:NEW_COLOR"

                    docker build --build-arg "APP_VERSION=$env:NEW_COLOR" -t $image .

                    if ($LASTEXITCODE -ne 0) {
                        throw "Docker image build failed"
                    }

                    Write-Output "Built image: $image"
                '''
            }
        }

        stage('Create Service If Missing') {
            steps {
                powershell '''
                    $serviceJson = kubectl get service blue-green-service -o json --ignore-not-found 2>$null

                    if ($LASTEXITCODE -ne 0) {
                        throw "Could not query Kubernetes service"
                    }

                    if ([string]::IsNullOrWhiteSpace($serviceJson)) {
                        Write-Output "Creating initial Kubernetes service"

                        kubectl apply -f k8s/service.yaml

                        if ($LASTEXITCODE -ne 0) {
                            throw "Service creation failed"
                        }
                    } else {
                        Write-Output "Existing service preserved"
                    }
                '''
            }
        }

        stage('Deploy New Environment') {
            steps {
                powershell '''
                    $color = $env:NEW_COLOR
                    $deployment = "blue-green-app-$color"

                    $yaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: blue-green-app
      version: $color
  template:
    metadata:
      labels:
        app: blue-green-app
        version: $color
    spec:
      containers:
        - name: blue-green-app
          image: blue-green-app:$color
          imagePullPolicy: Never
          ports:
            - containerPort: 80
"@

                    $yaml | Set-Content -Path "$deployment.yaml" -Encoding ASCII

                    kubectl apply -f "$deployment.yaml"

                    if ($LASTEXITCODE -ne 0) {
                        throw "Deployment creation failed"
                    }

                    kubectl rollout status deployment/$deployment --timeout=180s

                    if ($LASTEXITCODE -ne 0) {
                        throw "New environment did not become ready"
                    }

                    Write-Output "$color environment is ready"
                '''
            }
        }

        stage('Test New Environment') {
            steps {
                powershell '''
                    $color = $env:NEW_COLOR
                    $deployment = "blue-green-app-$color"

                    $pf = Start-Process -FilePath "kubectl.exe" `
                        -ArgumentList "port-forward deployment/$deployment 18080:80 --address=127.0.0.1" `
                        -PassThru -WindowStyle Hidden

                    try {
                        $healthy = $false

                        for ($i = 0; $i -lt 20; $i++) {
                            Start-Sleep -Seconds 2

                            if ($pf.HasExited) {
                                throw "Port forwarding stopped unexpectedly"
                            }

                            try {
                                $response = Invoke-WebRequest "http://127.0.0.1:18080" -UseBasicParsing -TimeoutSec 3

                                if ($response.StatusCode -eq 200 -and $response.Content -match $color.ToUpper()) {
                                    $healthy = $true
                                    break
                                }
                            }
                            catch {
                                # Retry while the application starts
                            }
                        }

                        if (!$healthy) {
                            throw "$color environment failed its HTTP health check"
                        }

                        Write-Output "$color environment passed HTTP health check"
                    }
                    finally {
                        if (!$pf.HasExited) {
                            Stop-Process -Id $pf.Id -Force
                        }
                    }
                '''
            }
        }

        stage('Switch Traffic') {
            steps {
                powershell '''
                    $color = $env:NEW_COLOR

                    $patch = @{
                        spec = @{
                            selector = @{
                                app = "blue-green-app"
                                version = $color
                            }
                        }
                    } | ConvertTo-Json -Compress

                    kubectl patch service blue-green-service --type=merge -p $patch

                    if ($LASTEXITCODE -ne 0) {
                        throw "Traffic switching failed"
                    }

                    Write-Output "Traffic switched to $color"
                '''

                script {
                    env.SWITCHED = 'true'
                }
            }
        }

        stage('Verify Live Deployment') {
            steps {
                powershell '''
                    kubectl get pods -o wide
                    kubectl get service blue-green-service
                    kubectl get endpoints blue-green-service

                    $endpoints = kubectl get endpoints blue-green-service -o jsonpath="{.subsets[*].addresses[*].ip}"

                    if ($LASTEXITCODE -ne 0 -or !$endpoints) {
                        throw "Service has no active endpoints"
                    }

                    Write-Output "Live traffic is reaching the new environment"
                '''
            }
        }
    }

    post {
        failure {
            script {
                if (env.SWITCHED == 'true' && env.OLD_COLOR in ['blue', 'green']) {
                    echo "Rolling back traffic to ${env.OLD_COLOR}"

                    powershell '''
                        $color = $env:OLD_COLOR

                        $patch = @{
                            spec = @{
                                selector = @{
                                    app = "blue-green-app"
                                    version = $color
                                }
                            }
                        } | ConvertTo-Json -Compress

                        kubectl patch service blue-green-service --type=merge -p $patch

                        if ($LASTEXITCODE -ne 0) {
                            throw "Rollback failed"
                        }

                        Write-Output "Traffic restored to $color"
                    '''
                } else {
                    echo 'No traffic switch occurred; previous service selection remains unchanged.'
                }
            }
        }

        success {
            echo 'Blue-Green deployment completed successfully!'
        }

        always {
            echo 'Pipeline execution finished.'
        }
    }
}
