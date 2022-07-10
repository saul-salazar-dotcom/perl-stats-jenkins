pipeline {
    agent any
    stages {
        stage('Generate CSV file') {
            steps {
                sh 'perl get_stats.pl > jenkins.csv'
            }
        }
    }
}
